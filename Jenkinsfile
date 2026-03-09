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
    AWS_REGION                = 'us-east-1'
    LS_AWS_ACCESS_KEY_ID      = credentials('LS_AWS_ACCESS_KEY_ID')
    LS_AWS_SECRET_ACCESS_KEY  = credentials('LS_AWS_SECRET_ACCESS_KEY')
    LS_ENDPOINT_URL           = credentials('LS_ENDPOINT_URL')
  }

  stages {
    stage('checkout') {
      steps {
        checkout scm
      }
    }

    stage('tooling check') {
      steps {
        sh '''
          set -euo pipefail
          command -v bash >/dev/null 2>&1
          command -v curl >/dev/null 2>&1
          command -v aws >/dev/null 2>&1
          aws --version
        '''
      }
    }

    stage('preflight localstack') {
      steps {
        sh '''
          set -euo pipefail

          export AWS_ACCESS_KEY_ID="$(printf '%s' "${LS_AWS_ACCESS_KEY_ID}" | tr -d '\\r\\n')"
          export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${LS_AWS_SECRET_ACCESS_KEY}" | tr -d '\\r\\n')"
          export AWS_REGION="${AWS_REGION}"
          export LS_ENDPOINT_URL="$(printf '%s' "${LS_ENDPOINT_URL}" | tr -d '\\r\\n')"

          bash scripts/localstack_infra.sh preflight
        '''
      }
    }

    stage('choose action') {
      steps {
        echo 'Waiting for runtime choice: apply, destroy, status, or abort.'
        script {
          def selectedAction = input(
            message: 'Choose how this pipeline should continue:',
            ok: 'Continue',
            parameters: [
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

          def actionValue = selectedAction['INFRA_ACTION'].trim()
          def enableEksValue = selectedAction['ENABLE_EKS'].trim()
          writeFile file: '.infra-action', text: "${actionValue}\n"
          writeFile file: '.infra-enable-eks', text: "${enableEksValue}\n"

          echo "Selected runtime action: ${actionValue}"
          echo "Selected ENABLE_EKS: ${enableEksValue}"

          if (actionValue == 'abort') {
            currentBuild.result = 'ABORTED'
            error('Pipeline aborted by user selection.')
          }
        }
      }
    }

    stage('run aws cli workflow') {
      steps {
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
      sh 'rm -f .infra-action .infra-enable-eks'
      archiveArtifacts artifacts: 'artifacts/*.env,artifacts/*.json', allowEmptyArchive: true
    }
  }
}
