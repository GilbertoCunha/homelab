terraform {
  # Cloudflare R2 speaks the S3 API, but not all of it. The skips below turn off
  # the checks that assume real AWS; `use_lockfile` replaces the DynamoDB table
  # AWS would use, and works because R2 supports conditional writes.
  backend "s3" {
    bucket = "homelab-tofu-state"
    key    = "talos/terraform.tfstate"
    region = "auto"

    endpoints = {
      s3 = "https://465654cb42ab6be3f9902b6cf3b4b282.r2.cloudflarestorage.com"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
    use_lockfile                = true
  }
}

# State holds the cluster PKI: the Talos and Kubernetes certificate authorities,
# including their private keys. It is not encrypted a second time on top of what
# R2 already does, which is a deliberate trade:
#
#   - OpenTofu has no age key provider, so encrypting here would mean inventing a
#     passphrase separate from the age key that guards everything else.
#   - That passphrase would have to live in secrets.enc.yaml, beside the R2
#     credentials. Anyone holding the age key would get both, so it would not
#     narrow the blast radius of the compromise people actually worry about.
#   - It would only help if the R2 credentials leaked on their own, or the bucket
#     were exposed.
#
# So the bucket is the control instead: keep it private, keep versioning on, and
# scope its API token to that one bucket.
