# SET UP VARIABLES

KUSTOMIZE := kubectl kustomize
APPLY := kubectl apply -f -
CURL := curl -s
YAML_URL := https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
BASE_DIR := base
OVERLAY_DIR := overlays
NUM_REPLICAS := 200
CONFIG_DIR_NAME := load-test-manifests


define log
echo "$$(date "+%Y-%m-%d %H:%M:%S %Z") $(1)"
endef


# K6 TEST TEMPLATE

define K6_TEST_TEMPLATE
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

// Custom metrics
const customTrend = new Trend('custom_trend');
const customRate = new Rate('custom_rate');
const customCounter = new Counter('custom_counter');

export const options = {
  scenarios: {
    ramp_up_scenario: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '20m', target: 5000 },  // Ramp-up to 50000 Virtual users (VUs) over 2 minutes
        { duration: '45m', target: 10000 }, // Ramp-up to 100000 VUs over next 5 minutes
        { duration: '72h', target: 10000 }, // Stay at 100000 VUs for 10 minutes
        { duration: '45m', target: 0 },     // Ramp-down to 0 VUs over 3 minutes
      ],
      gracefulRampDown: '2m',
    },
  },
  summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'max', 'count'],
};

export default function () {
  const url = 'http://bookinfo-productpage-[].k6-operator.svc.cluster.local:9080/productpage';
  const res = http.get(url);
  
  // Custom metrics
  customTrend.add(res.timings.duration);
  customRate.add(res.status === 200);
  customCounter.add(1);
  
  check(res, { 
    'status was 200': (r) => r.status == 200,
    'transaction time OK': (r) => r.timings.duration < 200
  });
  
  sleep(1);
}

export function handleSummary(data) {
  return {
    'stdout': JSON.stringify(data, null, 2),
    './summary.json': JSON.stringify(data),
  };
}
endef
export K6_TEST_TEMPLATE





# DEFINE K6 TASK TEMPLATE

define K6_TASK_TEMPLATE
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: bookinfo-productpage-[]-load-test
spec:
  parallelism: 2  #This number determines the number of pods in which the virtual users will be split
  script:
    configMap:
      name: k6-test-config-[]
      file: k6-test-[].js
  runner:
    env:
      - name: K6_WEB_DASHBOARD
        value: "true"
      - name: K6_WEB_DASHBOARD_EXPORT
        value: "html-report.html"
endef
export K6_TASK_TEMPLATE






.PHONY: install clean

install: $(BASE_DIR)/bookinfo.yaml $(BASE_DIR)/kustomization.yaml $(OVERLAY_DIR) $(CONFIG_DIR_NAME) $(CONFIG_DIR_NAME)/k6-task-%.yaml
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		$(call log, :: Installing replica $$(printf "%03d" $$i) of the application); \
		$(KUSTOMIZE) $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i) | $(APPLY) 2>&1 > /dev/null; \
		kubectl create configmap k6-test-config-$$(printf "%03d" $$i) --from-file=$(CONFIG_DIR_NAME)/k6-test-$$(printf "%03d" $$i).js 2>&1 > /dev/null; \
	done
	@$(call log, :: Sleeping 60 seconds before initiating load tests)
	@sleep 60
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		$(call log, :: Initiating load test for application $$(printf "%03d" $$i)); \
		kubectl apply -f $(CONFIG_DIR_NAME)/k6-task-$$(printf "%03d" $$i).yaml 2>&1 > /dev/null; \
	done
	@echo "========================================================"
	@echo " To access the dashboard, port forward to each pod using"
	@echo " kubectl port-forward pod/<pod_name> 5665"
	@echo "========================================================"

$(BASE_DIR)/bookinfo.yaml:
	@mkdir -p $(BASE_DIR)
	@$(CURL) $(YAML_URL) > $@

$(BASE_DIR)/kustomization.yaml:
	@echo "resources:" > $@
	@echo "- bookinfo.yaml" >> $@

$(OVERLAY_DIR):
	@mkdir -p $(OVERLAY_DIR)
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		mkdir -p $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i); \
		echo "resources:" > $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i)/kustomization.yaml; \
		echo "- ../../base" >> $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i)/kustomization.yaml; \
		echo "namePrefix: bookinfo-" >> $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i)/kustomization.yaml; \
		echo "nameSuffix: \"-$$(printf "%03d" $$i)\"" >> $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i)/kustomization.yaml; \
	done

$(CONFIG_DIR_NAME):
	@mkdir -p $(CONFIG_DIR_NAME)
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		number=$$(printf "%03d" $$i); \
		echo "$${K6_TEST_TEMPLATE}" | sed 's/\[\]/'"$$number"'/g' > $(CONFIG_DIR_NAME)/k6-test-$$number.js; \
	done

$(CONFIG_DIR_NAME)/k6-task-%.yaml:
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		number=$$(printf "%03d" $$i); \
		echo "$${K6_TASK_TEMPLATE}" | sed 's/\[\]/'"$$number"'/g' > $(CONFIG_DIR_NAME)/k6-task-$$number.yaml; \
	done


clean:
	@for i in $$(seq 1 $(NUM_REPLICAS)); do \
		$(call log, :: Deleting replica $$(printf "%03d" $$i) of the application); \
		$(KUSTOMIZE) $(OVERLAY_DIR)/overlay-$$(printf "%03d" $$i) | kubectl delete -f - 2>&1 > /dev/null; \
		kubectl delete configmap k6-test-config-$$(printf "%03d" $$i) 2>&1 > /dev/null; \
		$(call log, :: Deleting load test for application $$(printf "%03d" $$i)); \
		kubectl delete -f $(CONFIG_DIR_NAME)/k6-task-$$(printf "%03d" $$i).yaml 2>&1 > /dev/null; \
	done
	@rm -rf $(BASE_DIR) $(OVERLAY_DIR) $(CONFIG_DIR_NAME)
