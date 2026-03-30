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
              ),
              choice(
                name: 'SYNC_K8S_MAIL_ENV',
                choices: 'false\ntrue',
                description: 'Create/update Kubernetes mail Secret + ConfigMap from Jenkins credentials.'
              ),
              choice(
                name: 'SYNC_PUBLIC_K8S_ROUTES',
                choices: 'false\ntrue',
                description: 'Create/update the public nginx route include that forwards branded app paths into the k3d ingress.'
              ),
              string(
                name: 'K8S_NAMESPACE',
                defaultValue: 'hello-spring',
                description: 'Kubernetes namespace for the target Deployment.'
              ),
              string(
                name: 'K8S_DEPLOYMENT',
                defaultValue: 'hello-spring',
                description: 'Target Deployment name to patch with mail environment variables.'
              ),
              string(
                name: 'K8S_REMOTE_HOST',
                defaultValue: '68.155.156.136',
                description: 'Azure VM public IP or public DNS reachable from Jenkins. Do not use the Azure resource name or a local SSH alias.'
              ),
              string(
                name: 'K8S_REMOTE_PORT',
                defaultValue: '22',
                description: 'SSH port for the Azure VM.'
              ),
              string(
                name: 'K8S_REMOTE_CONTAINER',
                defaultValue: '',
                description: 'Optional k3d server container name. Leave blank to auto-detect the first k3d server-0 container.'
              ),
              string(
                name: 'PUBLIC_GATEWAY_SERVER_NAME',
                defaultValue: 'nauthappstest.tech',
                description: 'Public server_name configured in nginx on the Azure VM.'
              ),
              string(
                name: 'PUBLIC_GATEWAY_SITE_CONFIG',
                defaultValue: '',
                description: 'Optional exact nginx site config path on the Azure VM. Leave blank to auto-detect.'
              )
            ]
          )

          def deploymentValue = selectedAction['INFRA_DEPLOYMENT'].trim()
          def actionValue = selectedAction['INFRA_ACTION'].trim()
          def enableEksValue = selectedAction['ENABLE_EKS'].trim()
          def syncK8sMailValue = selectedAction['SYNC_K8S_MAIL_ENV'].trim()
          def syncPublicRoutesValue = selectedAction['SYNC_PUBLIC_K8S_ROUTES'].trim()
          def k8sNamespaceValue = selectedAction['K8S_NAMESPACE']?.trim() ?: 'hello-spring'
          def k8sDeploymentValue = selectedAction['K8S_DEPLOYMENT']?.trim() ?: 'hello-spring'
          def k8sRemoteHostValue = selectedAction['K8S_REMOTE_HOST']?.trim() ?: ''
          def k8sRemotePortValue = selectedAction['K8S_REMOTE_PORT']?.trim() ?: '22'
          def k8sRemoteContainerValue = selectedAction['K8S_REMOTE_CONTAINER']?.trim() ?: ''
          def publicGatewayServerNameValue = selectedAction['PUBLIC_GATEWAY_SERVER_NAME']?.trim() ?: 'nauthappstest.tech'
          def publicGatewaySiteConfigValue = selectedAction['PUBLIC_GATEWAY_SITE_CONFIG']?.trim() ?: ''
          writeFile file: '.infra-deployment', text: "${deploymentValue}\n"
          writeFile file: '.infra-action', text: "${actionValue}\n"
          writeFile file: '.infra-enable-eks', text: "${enableEksValue}\n"
          writeFile file: '.k8s-sync-mail-env', text: "${syncK8sMailValue}\n"
          writeFile file: '.public-gateway-sync', text: "${syncPublicRoutesValue}\n"
          writeFile file: '.k8s-namespace', text: "${k8sNamespaceValue}\n"
          writeFile file: '.k8s-deployment', text: "${k8sDeploymentValue}\n"
          writeFile file: '.k8s-remote-host', text: "${k8sRemoteHostValue}\n"
          writeFile file: '.k8s-remote-port', text: "${k8sRemotePortValue}\n"
          writeFile file: '.k8s-remote-container', text: "${k8sRemoteContainerValue}\n"
          writeFile file: '.public-gateway-server-name', text: "${publicGatewayServerNameValue}\n"
          writeFile file: '.public-gateway-site-config', text: "${publicGatewaySiteConfigValue}\n"

          echo "Selected deployment mode: ${deploymentValue}"
          echo "Selected runtime action: ${actionValue}"
          echo "Selected ENABLE_EKS: ${enableEksValue}"
          echo "Selected SYNC_K8S_MAIL_ENV: ${syncK8sMailValue}"
          echo "Selected SYNC_PUBLIC_K8S_ROUTES: ${syncPublicRoutesValue}"
          echo "Selected K8S_NAMESPACE: ${k8sNamespaceValue}"
          echo "Selected K8S_DEPLOYMENT: ${k8sDeploymentValue}"
          echo "Selected K8S_REMOTE_HOST: ${k8sRemoteHostValue}"
          echo "Selected K8S_REMOTE_PORT: ${k8sRemotePortValue}"
          echo "Selected K8S_REMOTE_CONTAINER: ${k8sRemoteContainerValue}"
          echo "Selected PUBLIC_GATEWAY_SERVER_NAME: ${publicGatewayServerNameValue}"
          echo "Selected PUBLIC_GATEWAY_SITE_CONFIG: ${publicGatewaySiteConfigValue}"

          if (syncK8sMailValue == 'true' && !k8sDeploymentValue) {
            error('K8S_DEPLOYMENT is required when SYNC_K8S_MAIL_ENV=true.')
          }

          if (syncK8sMailValue == 'true' && !k8sRemoteHostValue) {
            error('K8S_REMOTE_HOST is required when SYNC_K8S_MAIL_ENV=true.')
          }

          if (syncPublicRoutesValue == 'true' && !k8sRemoteHostValue) {
            error('K8S_REMOTE_HOST is required when SYNC_PUBLIC_K8S_ROUTES=true.')
          }

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
          K8S_SYNC_VALUE="$(tr -d '\\r\\n' < .k8s-sync-mail-env)"
          PUBLIC_GATEWAY_SYNC_VALUE="$(tr -d '\\r\\n' < .public-gateway-sync)"

          command -v bash >/dev/null 2>&1
          command -v curl >/dev/null 2>&1
          command -v aws >/dev/null 2>&1
          aws --version

          if [ "${DEPLOYMENT_VALUE}" = "terraform" ]; then
            command -v terraform >/dev/null 2>&1
            terraform version
          fi

          if [ "${K8S_SYNC_VALUE}" = "true" ] || [ "${PUBLIC_GATEWAY_SYNC_VALUE}" = "true" ]; then
            command -v ssh >/dev/null 2>&1
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

    stage('sync k8s mail env') {
      steps {
        script {
          def actionValue = readFile('.infra-action').trim()
          def syncK8sMailValue = readFile('.k8s-sync-mail-env').trim()

          if (syncK8sMailValue != 'true') {
            echo 'Skipping Kubernetes mail sync because SYNC_K8S_MAIL_ENV=false.'
          } else if (actionValue == 'destroy') {
            echo 'Skipping Kubernetes mail sync because INFRA_ACTION=destroy.'
          } else {
            withCredentials([
              string(credentialsId: 'MAIL_HOST', variable: 'MAIL_HOST'),
              string(credentialsId: 'MAIL_PORT', variable: 'MAIL_PORT'),
              string(credentialsId: 'MAIL_USERNAME', variable: 'MAIL_USERNAME'),
              string(credentialsId: 'MAIL_PASSWORD', variable: 'MAIL_PASSWORD'),
              string(credentialsId: 'APP_CONTACT_MAIL_FROM', variable: 'APP_CONTACT_MAIL_FROM'),
              sshUserPrivateKey(credentialsId: 'VM_SSH_KEY', keyFileVariable: 'SSH_KEY_FILE', usernameVariable: 'SSH_USERNAME')
            ]) {
              sh '''
                set -euo pipefail
                export K8S_ACCESS_MODE=ssh-docker
                export K8S_NAMESPACE="$(tr -d '\\r\\n' < .k8s-namespace)"
                export K8S_DEPLOYMENT="$(tr -d '\\r\\n' < .k8s-deployment)"
                export K8S_REMOTE_HOST="$(tr -d '\\r\\n' < .k8s-remote-host)"
                export K8S_REMOTE_PORT="$(tr -d '\\r\\n' < .k8s-remote-port)"
                export K8S_REMOTE_CONTAINER="$(tr -d '\\r\\n' < .k8s-remote-container)"
                export K8S_REMOTE_USER="${SSH_USERNAME}"

                bash scripts/k8s_mail_env.sh apply
              '''
            }
          }
        }
      }
    }

    stage('sync public gateway routes') {
      steps {
        script {
          def actionValue = readFile('.infra-action').trim()
          def syncPublicRoutesValue = readFile('.public-gateway-sync').trim()

          if (syncPublicRoutesValue != 'true') {
            echo 'Skipping public gateway route sync because SYNC_PUBLIC_K8S_ROUTES=false.'
          } else if (actionValue == 'destroy') {
            echo 'Skipping public gateway route sync because INFRA_ACTION=destroy.'
          } else {
            withCredentials([
              sshUserPrivateKey(credentialsId: 'VM_SSH_KEY', keyFileVariable: 'SSH_KEY_FILE', usernameVariable: 'SSH_USERNAME')
            ]) {
              sh '''
                set -euo pipefail
                export PUBLIC_GATEWAY_ACCESS_MODE=ssh
                export PUBLIC_GATEWAY_REMOTE_HOST="$(tr -d '\\r\\n' < .k8s-remote-host)"
                export PUBLIC_GATEWAY_REMOTE_PORT="$(tr -d '\\r\\n' < .k8s-remote-port)"
                export PUBLIC_GATEWAY_REMOTE_USER="${SSH_USERNAME}"
                export PUBLIC_GATEWAY_SERVER_NAME="$(tr -d '\\r\\n' < .public-gateway-server-name)"
                export PUBLIC_GATEWAY_SITE_CONFIG="$(tr -d '\\r\\n' < .public-gateway-site-config)"

                bash scripts/public_k8s_gateway_routes.sh apply
              '''
            }
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
      sh 'rm -f tfplan .infra-deployment .infra-action .infra-enable-eks .k8s-sync-mail-env .public-gateway-sync .k8s-namespace .k8s-deployment .k8s-remote-host .k8s-remote-port .k8s-remote-container .public-gateway-server-name .public-gateway-site-config'
      archiveArtifacts artifacts: 'artifacts/*.env,artifacts/*.json,artifacts/*.txt', allowEmptyArchive: true
    }
  }
}
