pipeline {
  agent any

  triggers {
    githubPush()
  }

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
  }

  environment {
    TF_IN_AUTOMATION      = 'true'
    TF_INPUT              = 'false'
    TF_CLI_ARGS           = '-no-color'
    TF_PARALLELISM        = '1'
    TF_VAR_aws_region     = 'us-east-1'
    TFSTATE_STORAGE_ACCOUNT = 'alejatfstate2026demo'
    TFSTATE_CONTAINER       = 'tfstate'
    TFSTATE_KEY             = 'localstack-terraform-jenkins.tfstate'
    ARM_USE_AZUREAD         = 'true'

    LS_AWS_ACCESS_KEY_ID     = credentials('LS_AWS_ACCESS_KEY_ID')
    LS_AWS_SECRET_ACCESS_KEY = credentials('LS_AWS_SECRET_ACCESS_KEY')
    LS_ENDPOINT_URL          = credentials('LS_ENDPOINT_URL')

    ARM_CLIENT_ID       = credentials('ARM_CLIENT_ID')
    ARM_CLIENT_SECRET   = credentials('ARM_CLIENT_SECRET')
    ARM_TENANT_ID       = credentials('ARM_TENANT_ID')
    ARM_SUBSCRIPTION_ID = credentials('ARM_SUBSCRIPTION_ID')

    TFSTATE_RESOURCE_GROUP = credentials('TFSTATE_RESOURCE_GROUP')
  }

  stages {
    stage('checkout') {
      steps {
        checkout scm
      }
    }

    stage('terraform init') {
      steps {
        sh '''
          set -euo pipefail

          if [ -z "${TFSTATE_STORAGE_ACCOUNT:-}" ]; then
            echo "TFSTATE_STORAGE_ACCOUNT is required."
            exit 1
          fi

          LS_ENDPOINT_URL_CLEAN="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"
          if [ -z "${LS_ENDPOINT_URL_CLEAN}" ]; then
            echo "LS_ENDPOINT_URL is required."
            exit 1
          fi

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL_CLEAN}"

          terraform init -reconfigure -input=false \
            -backend-config="resource_group_name=${TFSTATE_RESOURCE_GROUP}" \
            -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
            -backend-config="container_name=${TFSTATE_CONTAINER}" \
            -backend-config="key=${TFSTATE_KEY}"
        '''
      }
    }

    stage('preflight localstack') {
      steps {
        sh '''
          set -euo pipefail

          LS_ENDPOINT_URL_CLEAN="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"
          HEALTH_URL="${LS_ENDPOINT_URL_CLEAN}/_localstack/health"

          if ! command -v curl >/dev/null 2>&1; then
            echo "curl is required on the Jenkins agent."
            exit 1
          fi

          echo "Checking LocalStack health endpoint: ${HEALTH_URL}"
          curl -fsS --retry 5 --retry-delay 2 --retry-all-errors --max-time 20 "${HEALTH_URL}" > /tmp/localstack-health.json

          if grep -qi '"running"[[:space:]]*:[[:space:]]*false' /tmp/localstack-health.json; then
            echo "LocalStack reports non-running services:"
            cat /tmp/localstack-health.json
            rm -f /tmp/localstack-health.json
            exit 1
          fi

          rm -f /tmp/localstack-health.json
        '''
      }
    }

    stage('fmt/validate') {
      steps {
        sh '''
          set -euo pipefail
          terraform fmt -check -recursive
          terraform validate
        '''
      }
    }

    stage('choose action') {
      steps {
        echo 'Waiting for runtime choice: apply, destroy, or abort.'
        script {
          def selectedAction = input(
            message: 'Do you want apply, destroy, or abort?',
            ok: 'Continue',
            parameters: [
              choice(
                name: 'TF_ACTION',
                choices: 'apply\ndestroy\nabort',
                description: 'Choose how this pipeline should continue.'
              ),
              choice(
                name: 'ENABLE_EKS',
                choices: 'false\ntrue',
                description: 'Enable EKS resources for this run (false is recommended for clean baseline runs).'
              )
            ]
          )

          def actionValue = selectedAction['TF_ACTION'].trim()
          def enableEksValue = selectedAction['ENABLE_EKS'].trim()
          writeFile file: '.terraform-action', text: "${actionValue}\n"
          writeFile file: '.terraform-enable-eks', text: "${enableEksValue}\n"
          echo "Selected runtime action: ${actionValue}"
          echo "Selected enable_eks: ${enableEksValue}"

          if (actionValue == 'abort') {
            currentBuild.result = 'ABORTED'
            error('Pipeline aborted by user selection.')
          }
        }
      }
    }

    stage('plan') {
      steps {
        sh '''
          set -euo pipefail
          ACTION_VALUE="$(tr -d '\\r\\n' < .terraform-action)"
          ENABLE_EKS_VALUE="$(tr -d '\\r\\n' < .terraform-enable-eks)"
          LS_ENDPOINT_URL_CLEAN="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL_CLEAN}"

          if [ "${ACTION_VALUE}" = "destroy" ]; then
            terraform plan -parallelism="${TF_PARALLELISM}" -destroy -var="enable_eks=${ENABLE_EKS_VALUE}" -out=tfplan
          else
            terraform plan -parallelism="${TF_PARALLELISM}" -var="enable_eks=${ENABLE_EKS_VALUE}" -out=tfplan
          fi
        '''
      }
    }

    stage('apply/destroy') {
      steps {
        sh '''
          set -euo pipefail
          LS_ENDPOINT_URL_CLEAN="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL_CLEAN}"

          terraform apply -parallelism="${TF_PARALLELISM}" -auto-approve tfplan
        '''
      }
    }
  }

  post {
    always {
      sh 'rm -f tfplan .terraform-action .terraform-enable-eks'
    }
  }
}
