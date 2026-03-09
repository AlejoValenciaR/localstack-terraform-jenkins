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
    TF_IN_AUTOMATION        = 'true'
    TF_INPUT                = 'false'
    TF_CLI_ARGS             = '-no-color'
    TF_PARALLELISM          = '1'
    TF_DISABLE_BACKEND      = 'false'
    TFSTATE_STORAGE_ACCOUNT = 'alejatfstate2026demo'
    TFSTATE_CONTAINER       = 'tfstate'
    TFSTATE_KEY             = 'localstack-terraform-jenkins.tfstate'
    ARM_USE_AZUREAD         = 'true'

    AWS_REGION               = 'us-east-1'
    LS_AWS_ACCESS_KEY_ID     = credentials('LS_AWS_ACCESS_KEY_ID')
    LS_AWS_SECRET_ACCESS_KEY = credentials('LS_AWS_SECRET_ACCESS_KEY')
    LS_ENDPOINT_URL          = credentials('LS_ENDPOINT_URL')
  }

  stages {
    stage('checkout') {
      steps {
        checkout scm
      }
    }

    stage('choose workflow') {
      steps {
        echo 'Waiting for runtime choice: terraform/awscli + apply/destroy/status/abort.'
        script {
          def selectedAction = input(
            message: 'Choose deployment mode and runtime action:',
            ok: 'Continue',
            parameters: [
              choice(
                name: 'INFRA_DEPLOYMENT',
                choices: 'terraform\nawscli',
                description: 'terraform runs Terraform IaC; awscli runs ordered AWS CLI commands.'
              ),
              choice(
                name: 'INFRA_ACTION',
                choices: 'apply\ndestroy\nstatus\nabort',
                description: 'apply creates/updates resources, destroy deletes resources, status reads resources only.'
              ),
              choice(
                name: 'ENABLE_EKS',
                choices: 'false\ntrue',
                description: 'Enable optional EKS flow (false recommended while you learn).'
              )
            ]
          )

          def deploymentValue = selectedAction['INFRA_DEPLOYMENT'].trim()
          def actionValue = selectedAction['INFRA_ACTION'].trim()
          def enableEksValue = selectedAction['ENABLE_EKS'].trim()
          writeFile file: '.infra-deployment', text: "${deploymentValue}\n"
          writeFile file: '.infra-action', text: "${actionValue}\n"
          writeFile file: '.infra-enable-eks', text: "${enableEksValue}\n"

          echo "Selected deployment mode: ${deploymentValue}"
          echo "Selected runtime action: ${actionValue}"
          echo "Selected ENABLE_EKS: ${enableEksValue}"

          if (actionValue == 'abort') {
            currentBuild.result = 'ABORTED'
            error('Pipeline aborted by user selection.')
          }
        }
      }
    }

    stage('tooling check') {
      steps {
        sh '''
          set -euo pipefail
          DEPLOYMENT_VALUE="$(tr -d '\\r\\n' < .infra-deployment)"

          command -v bash >/dev/null 2>&1
          command -v curl >/dev/null 2>&1
          command -v aws >/dev/null 2>&1
          aws --version

          if [ "${DEPLOYMENT_VALUE}" = "terraform" ]; then
            command -v terraform >/dev/null 2>&1
            terraform version
          fi
        '''
      }
    }

    stage('run selected workflow') {
      steps {
        script {
          def deploymentValue = readFile('.infra-deployment').trim()

          if (deploymentValue == 'awscli') {
            sh '''
              set -euo pipefail
              ACTION_VALUE="$(tr -d '\\r\\n' < .infra-action)"
              ENABLE_EKS_VALUE="$(tr -d '\\r\\n' < .infra-enable-eks)"

              export AWS_ACCESS_KEY_ID="$(printf '%s' "${LS_AWS_ACCESS_KEY_ID}" | tr -d '\\r\\n')"
              export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${LS_AWS_SECRET_ACCESS_KEY}" | tr -d '\\r\\n')"
              export AWS_REGION="${AWS_REGION}"
              export LS_ENDPOINT_URL="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"
              export ENABLE_EKS="${ENABLE_EKS_VALUE}"

              bash scripts/localstack_infra.sh "${ACTION_VALUE}"
            '''
          } else if (deploymentValue == 'terraform') {
            if (env.TF_DISABLE_BACKEND?.trim()?.toLowerCase() == 'true') {
              sh '''
                set -euo pipefail
                ACTION_VALUE="$(tr -d '\\r\\n' < .infra-action)"
                ENABLE_EKS_VALUE="$(tr -d '\\r\\n' < .infra-enable-eks)"

                export AWS_ACCESS_KEY_ID="$(printf '%s' "${LS_AWS_ACCESS_KEY_ID}" | tr -d '\\r\\n')"
                export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${LS_AWS_SECRET_ACCESS_KEY}" | tr -d '\\r\\n')"
                export AWS_REGION="${AWS_REGION}"
                export LS_ENDPOINT_URL="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"
                export ENABLE_EKS="${ENABLE_EKS_VALUE}"

                export TF_IN_AUTOMATION="${TF_IN_AUTOMATION}"
                export TF_INPUT="${TF_INPUT}"
                export TF_CLI_ARGS="${TF_CLI_ARGS}"
                export TF_PARALLELISM="${TF_PARALLELISM}"
                export TF_DISABLE_BACKEND="${TF_DISABLE_BACKEND}"
                export TFSTATE_STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT}"
                export TFSTATE_CONTAINER="${TFSTATE_CONTAINER}"
                export TFSTATE_KEY="${TFSTATE_KEY}"
                export ARM_USE_AZUREAD="${ARM_USE_AZUREAD}"

                bash scripts/terraform_infra.sh "${ACTION_VALUE}"
              '''
            } else {
              withCredentials([
                string(credentialsId: 'ARM_CLIENT_ID', variable: 'ARM_CLIENT_ID'),
                string(credentialsId: 'ARM_CLIENT_SECRET', variable: 'ARM_CLIENT_SECRET'),
                string(credentialsId: 'ARM_TENANT_ID', variable: 'ARM_TENANT_ID'),
                string(credentialsId: 'ARM_SUBSCRIPTION_ID', variable: 'ARM_SUBSCRIPTION_ID'),
                string(credentialsId: 'TFSTATE_RESOURCE_GROUP', variable: 'TFSTATE_RESOURCE_GROUP')
              ]) {
                sh '''
                  set -euo pipefail
                  ACTION_VALUE="$(tr -d '\\r\\n' < .infra-action)"
                  ENABLE_EKS_VALUE="$(tr -d '\\r\\n' < .infra-enable-eks)"

                  export AWS_ACCESS_KEY_ID="$(printf '%s' "${LS_AWS_ACCESS_KEY_ID}" | tr -d '\\r\\n')"
                  export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${LS_AWS_SECRET_ACCESS_KEY}" | tr -d '\\r\\n')"
                  export AWS_REGION="${AWS_REGION}"
                  export LS_ENDPOINT_URL="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"
                  export ENABLE_EKS="${ENABLE_EKS_VALUE}"

                  export TF_IN_AUTOMATION="${TF_IN_AUTOMATION}"
                  export TF_INPUT="${TF_INPUT}"
                  export TF_CLI_ARGS="${TF_CLI_ARGS}"
                  export TF_PARALLELISM="${TF_PARALLELISM}"
                  export TF_DISABLE_BACKEND="${TF_DISABLE_BACKEND}"
                  export TFSTATE_STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT}"
                  export TFSTATE_CONTAINER="${TFSTATE_CONTAINER}"
                  export TFSTATE_KEY="${TFSTATE_KEY}"
                  export ARM_USE_AZUREAD="${ARM_USE_AZUREAD}"

                  bash scripts/terraform_infra.sh "${ACTION_VALUE}"
                '''
              }
            }
          } else {
            error("Unsupported INFRA_DEPLOYMENT value: ${deploymentValue}")
          }
        }
      }
    }

    stage('show outputs') {
      when {
        expression { fileExists('artifacts/outputs.env') }
      }
      steps {
        sh 'cat artifacts/outputs.env'
      }
    }
  }

  post {
    always {
      sh 'rm -f tfplan .infra-deployment .infra-action .infra-enable-eks'
      archiveArtifacts artifacts: 'artifacts/*.env,artifacts/*.json,artifacts/*.txt', allowEmptyArchive: true
    }
  }
}
