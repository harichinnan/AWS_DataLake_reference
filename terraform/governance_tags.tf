###############################################################################
# Lake Formation tag taxonomy + tag-based grants.                             #
#                                                                             #
# Pattern: the platform team owns the *taxonomy* — what tag keys exist, what  #
# values are allowed, and which principals see what. The data team owns the   #
# *assignment* — applying tag values to tables via dbt's lf_tags_config.      #
#                                                                             #
# All resources here are gated on var.enable_lake_formation_governance to     #
# match the rest of the LF setup.                                             #
###############################################################################

locals {
  lf_tags_enabled = var.enable_lake_formation_governance

  # Taxonomy. The keys and allowed values are policy decisions; dbt models pick
  # one value per key in their lf_tags_config block.
  lf_tag_taxonomy = {
    domain = {
      values = ["trips", "stations", "observability"]
    }
    pii_level = {
      values = ["none", "low", "medium", "high"]
    }
    freshness_tier = {
      values = ["raw", "daily", "monthly", "snapshot"]
    }
    layer = {
      values = ["bronze", "silver", "gold"]
    }
  }
}

resource "aws_lakeformation_lf_tag" "taxonomy" {
  for_each = local.lf_tags_enabled ? local.lf_tag_taxonomy : {}

  catalog_id = data.aws_caller_identity.current.account_id
  key        = each.key
  values     = each.value.values
}

###############################################################################
# Grant taxonomy permissions to data team and platform admins.
# Anyone listed here can ASSIGN tag values; querying by tag is a separate
# grant (below).
###############################################################################

locals {
  lf_tag_admin_principals = local.lf_tags_enabled ? merge(
    { for idx, arn in var.lake_formation_admin_principal_arns : "admin-${idx}" => arn },
    local.pipeline_orchestration_active ? {
      dbt_runner   = aws_iam_role.dbt_runner_task[0].arn,
      gha_pipeline = aws_iam_role.gha_pipeline.arn,
      } : {
      gha_pipeline = aws_iam_role.gha_pipeline.arn,
    }
  ) : {}
}

resource "aws_lakeformation_permissions" "lf_tag_assign" {
  for_each = {
    for pair in setproduct(keys(local.lf_tag_admin_principals), keys(local.lf_tag_taxonomy)) :
    "${pair[0]}-${pair[1]}" => {
      principal = local.lf_tag_admin_principals[pair[0]]
      tag_key   = pair[1]
      values    = local.lf_tag_taxonomy[pair[1]].values
    } if local.lf_tags_enabled
  }

  principal                     = each.value.principal
  permissions                   = ["ASSOCIATE"]
  permissions_with_grant_option = []

  lf_tag {
    key    = each.value.tag_key
    values = each.value.values
  }

  depends_on = [aws_lakeformation_lf_tag.taxonomy]
}

###############################################################################
# Tag-based table grants.
#
# Example policy: any principal granted the (pii_level = none|low) tag combo
# can SELECT from any table carrying those tags. Metabase and dbt runner get
# this grant so they can read curated tables without per-table grants.
###############################################################################

locals {
  # Principals that can SELECT any (pii_level in [none, low]) table
  lf_tag_select_principals = local.lf_tags_enabled ? merge(
    var.enable_metabase ? { metabase = aws_iam_role.metabase_task[0].arn } : {},
    local.pipeline_orchestration_active ? { dbt_runner = aws_iam_role.dbt_runner_task[0].arn } : {},
  ) : {}
}

resource "aws_lakeformation_permissions" "tag_based_select" {
  for_each = local.lf_tag_select_principals

  principal   = each.value
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"
    expression {
      key    = "pii_level"
      values = ["none", "low"]
    }
  }

  depends_on = [
    aws_lakeformation_lf_tag.taxonomy,
    aws_lakeformation_resource.lake,
  ]
}

output "lf_tag_taxonomy_keys" {
  description = "Tag keys defined in the governance taxonomy."
  value       = local.lf_tags_enabled ? sort(keys(local.lf_tag_taxonomy)) : []
}
