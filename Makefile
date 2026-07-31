.PHONY: check fmt fmt-fix validate lint test docs docs-check goldens clean

TF_DIRS := . examples/complete modules/chart_values
CHART_VALUES := modules/chart_values
GOLDEN_STATE := .golden.tfstate

# What CI runs. No AWS credentials are needed for any of it.
check: fmt validate lint docs-check test

fmt:
	terraform fmt -recursive -check -diff

fmt-fix:
	terraform fmt -recursive

# -backend=false so this works with no state backend configured, which is also
# how a customer's first `terraform validate` behaves before they pick one.
validate:
	@for dir in $(TF_DIRS); do \
		echo "==> validate $$dir"; \
		terraform -chdir=$$dir init -backend=false -input=false >/dev/null || exit 1; \
		terraform -chdir=$$dir validate || exit 1; \
	done

lint:
	tflint --init
	tflint --recursive

test:
	terraform -chdir=. init -backend=false -input=false >/dev/null
	terraform -chdir=. test
	terraform -chdir=$(CHART_VALUES) init -backend=false -input=false >/dev/null
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

# Re-render the golden files. The chart_values module declares no provider, so it
# can be applied directly with no credentials and no network.
goldens:
	terraform -chdir=$(CHART_VALUES) init -backend=false -input=false >/dev/null
	terraform -chdir=$(CHART_VALUES) apply -auto-approve -input=false \
		-var-file=tests/fixture.tfvars -state=$(GOLDEN_STATE) >/dev/null
	terraform -chdir=$(CHART_VALUES) output -state=$(GOLDEN_STATE) -raw helm_values \
		> $(CHART_VALUES)/tests/golden_values.yaml
	terraform -chdir=$(CHART_VALUES) output -state=$(GOLDEN_STATE) -raw ingress_class_manifest \
		> $(CHART_VALUES)/tests/golden_ingressclass.yaml
	rm -f $(CHART_VALUES)/$(GOLDEN_STATE) $(CHART_VALUES)/$(GOLDEN_STATE).backup
	@echo "Golden files re-rendered. Review the diff before committing."

clean:
	rm -rf .terraform examples/complete/.terraform $(CHART_VALUES)/.terraform
	rm -f .terraform.lock.hcl examples/complete/.terraform.lock.hcl $(CHART_VALUES)/.terraform.lock.hcl
	rm -f $(CHART_VALUES)/$(GOLDEN_STATE) $(CHART_VALUES)/$(GOLDEN_STATE).backup
