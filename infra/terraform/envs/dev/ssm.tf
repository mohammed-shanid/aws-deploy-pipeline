# The only thing CI may run on the host (ADR 0002): the deploy script with one
# argument that must be a 40-character git SHA. Not AWS-RunShellScript.
resource "aws_ssm_document" "deploy" {
  name            = "${var.project}-deploy"
  document_type   = "Command"
  document_format = "JSON"
  target_type     = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy one release of ${var.project} by git SHA"
    parameters = {
      sha = {
        type           = "String"
        description    = "Full 40-character git SHA of the image to deploy"
        allowedPattern = "^[0-9a-f]{40}$"
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        timeoutSeconds = "300"
        runCommand     = ["/opt/app/bin/deploy {{ sha }}"]
      }
    }]
  })
}
