pipeline {
  agent any

  triggers {
    githubPush()
  }

  options {
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    choice(name: 'ACTION', choices: ['plan', 'apply', 'destroy'], description: 'Terraform action to run.')
    string(name: 'TFSTATE_STORAGE_ACCOUNT', defaultValue: 'alejatfstate2026demo', description: 'Azure Storage account name for Terraform state.')
    string(name: 'TFSTATE_CONTAINER', defaultValue: 'tfstate', description: 'Azure Blob container name for Terraform state.')
    string(name: 'TFSTATE_KEY', defaultValue: 'localstack-terraform-jenkins.tfstate', description: 'State file key in the Azure Blob container.')
  }

  environment {
    TF_IN_AUTOMATION      = 'true'
    TF_INPUT              = 'false'
    TF_VAR_aws_region     = 'us-east-1'

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

          if [ -z "${TFSTATE_STORAGE_ACCOUNT}" ]; then
            echo "TFSTATE_STORAGE_ACCOUNT parameter is required."
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
            -backend-config="key=${TFSTATE_KEY}" \
            -backend-config="subscription_id=${ARM_SUBSCRIPTION_ID}" \
            -backend-config="tenant_id=${ARM_TENANT_ID}" \
            -backend-config="client_id=${ARM_CLIENT_ID}" \
            -backend-config="client_secret=${ARM_CLIENT_SECRET}"
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

    stage('plan') {
      steps {
        sh '''
          set -euo pipefail

          export AWS_ACCESS_KEY_ID="${LS_AWS_ACCESS_KEY_ID}"
          export AWS_SECRET_ACCESS_KEY="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_aws_access_key="${LS_AWS_ACCESS_KEY_ID}"
          export TF_VAR_aws_secret_key="${LS_AWS_SECRET_ACCESS_KEY}"
          export TF_VAR_localstack_endpoint_url="${LS_ENDPOINT_URL}"

          if [ "${ACTION}" = "destroy" ]; then
            terraform plan -destroy -out=tfplan
          else
            terraform plan -out=tfplan
          fi
        '''
      }
    }

    stage('manual approval') {
      when {
        expression { params.ACTION == 'apply' || params.ACTION == 'destroy' }
      }
      steps {
        input message: "Approve Terraform ${params.ACTION}?", ok: 'Proceed'
      }
    }

    stage('apply/destroy') {
      when {
        expression { params.ACTION == 'apply' || params.ACTION == 'destroy' }
      }
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
