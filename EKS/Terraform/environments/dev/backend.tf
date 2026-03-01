terraform {
  backend "s3" {
    bucket       = "ecs-fragate-tf-file"
    key          = "php-keda/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
  }
}
