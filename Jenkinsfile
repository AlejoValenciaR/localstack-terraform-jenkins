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
    TF_VAR_aws_region     = 'us-east-1'
    TFSTATE_STORAGE_ACCOUNT = 'alejatfstate2026demo'
    TFSTATE_CONTAINER       = 'tfstate'
    TFSTATE_KEY             = 'localstack-terraform-jenkins.tfstate'
    TF_ACTION              = ''
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

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL}"

          terraform init -reconfigure -input=false \
            -backend-config="resource_group_name=${TFSTATE_RESOURCE_GROUP}" \
            -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
            -backend-config="container_name=${TFSTATE_CONTAINER}" \
            -backend-config="key=${TFSTATE_KEY}"
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
          env.TF_ACTION = input(
            message: 'Do you want apply, destroy, or abort?',
            ok: 'Continue',
            parameters: [
              choice(
                name: 'TF_ACTION',
                choices: 'apply\ndestroy\nabort',
                description: 'Choose how this pipeline should continue.'
              )
            ]
          )

          if (env.TF_ACTION == 'abort') {
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

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL}"

          if [ "${TF_ACTION}" = "destroy" ]; then
            terraform plan -destroy -out=tfplan
          else
            terraform plan -out=tfplan
          fi
        '''
      }
    }

    stage('apply/destroy') {
      steps {
        sh '''
          set -euo pipefail

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL}"

          terraform apply -auto-approve tfplan
        '''
      }
    }
  }

  post {
    always {
      sh 'rm -f tfplan'
    }
  }
}
