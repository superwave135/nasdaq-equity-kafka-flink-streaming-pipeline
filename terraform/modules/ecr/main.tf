###############################################################################
# ECR — Container Repositories
###############################################################################

resource "aws_ecr_repository" "repos" {
  for_each             = toset(var.repositories)
  name                 = "${var.name_prefix}-${each.value}"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.environment == "dev"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "${var.name_prefix}-${each.value}" }
}

# Lifecycle policy: keep only the last 5 images per repo
resource "aws_ecr_lifecycle_policy" "repos" {
  for_each   = toset(var.repositories)
  repository = aws_ecr_repository.repos[each.value].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
