.PHONY: check fmt fmt-fix validate lint test docs docs-check

TF_DIRS := . examples/complete modules/chart_values
CHART_VALUES := modules/chart_values

# What CI runs.
check: fmt validate lint docs-check test

fmt:
	terraform fmt -recursive -check -diff

fmt-fix:
	terraform fmt -recursive

# -backend=false so this works with no state backend configured, which is also how
# a customer's first `terraform validate` behaves before they pick one. -upgrade
# because this repo does not commit lock files: without it, a leftover local lock
# from an older provider constraint fails init rather than resolving afresh.
validate:
	@for dir in $(TF_DIRS); do \
		echo "==> validate $$dir"; \
		terraform -chdir=$$dir init -backend=false -input=false -upgrade >/dev/null || exit 1; \
		terraform -chdir=$$dir validate || exit 1; \
	done

lint:
	tflint --init
	tflint --recursive

test:
	terraform -chdir=. init -backend=false -input=false -upgrade >/dev/null
	terraform -chdir=. test
	terraform -chdir=$(CHART_VALUES) init -backend=false -input=false -upgrade >/dev/null
	terraform -chdir=$(CHART_VALUES) test

docs:
	terraform-docs -c .terraform-docs.yml .
	terraform-docs -c .terraform-docs.yml examples/complete
	terraform-docs -c .terraform-docs.yml $(CHART_VALUES)

# Fails if the generated tables in the READMEs are stale.
docs-check:
	terraform-docs -c .terraform-docs.yml --output-check .
	terraform-docs -c .terraform-docs.yml --output-check examples/complete
	terraform-docs -c .terraform-docs.yml --output-check $(CHART_VALUES)

