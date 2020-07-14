########################################################################################################################
#
# When adding a new target:
#   - If you are adding a new service make sure the dev.reset target will fully reset said service.
#
########################################################################################################################
.DEFAULT_GOAL := help
.PHONY: requirements

OS := $(shell uname)

COMPOSE_PROJECT_NAME ?= $(shell grep COMPOSE_PROJECT_NAME= local*.sh | cut -f 2 -d =)
DEVSTACK_WORKSPACE ?= $(shell pwd)/..
OPENEDX_RELEASE ?= $(shell grep OPENEDX_RELEASE= local*.sh | cut -f 2 -d =)
export COMPOSE_PROJECT_NAME
export DEVSTACK_WORKSPACE
export OPENEDX_RELEASE

include *.mk

# Generates a help message. Borrowed from https://github.com/pydanny/cookiecutter-djangopackage.
help: ## Display this help message
	@echo "Please use \`make <target>' where <target> is one of"
	@perl -nle'print $& if m{^[\.a-zA-Z_-]+:.*?## .*$$}' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m  %-25s\033[0m %s\n", $$1, $$2}'

requirements: ## Install requirements
	pip install -r requirements/base.txt

upgrade: ## Upgrade requirements with pip-tools
	pip install -qr requirements/pip-tools.txt
	pip-compile --upgrade -o requirements/pip-tools.txt requirements/pip-tools.in
	pip-compile --upgrade -o requirements/base.txt requirements/base.in
	bash post-pip-compile.sh \
		requirements/pip-tools.txt \
		requirements/base.txt \

dev.print-container.%: ## Get the ID of the running container for a given service. Run with ``make --silent`` for just ID.
	@echo $$(docker-compose ps --quiet $*)

dev.ps: ## View list of created services and their statuses.
	docker-compose ps

dev.checkout: ## Check out "openedx-release/$OPENEDX_RELEASE" in each repo if set, "master" otherwise
	./repo.sh checkout

dev.clone: ## Clone service repos to the parent directory
	./repo.sh clone

dev.provision.run: ## Provision all services with local mounted directories
	DOCKER_COMPOSE_FILES="-f docker-compose.yml -f docker-compose-host.yml" ./provision.sh

dev.provision: | check-memory dev.clone dev.provision.run stop ## Provision dev environment with all services stopped

dev.provision.xqueue: | check-memory dev.provision.xqueue.run stop stop.xqueue

dev.provision.xqueue.run:
	DOCKER_COMPOSE_FILES="-f docker-compose.yml -f docker-compose-xqueue.yml" ./provision-xqueue.sh

dev.reset: | down dev.repo.reset pull dev.up static update-db ## Attempts to reset the local devstack to a the master working state

dev.status: ## Prints the status of all git repositories
	./repo.sh status

dev.repo.reset: ## Attempts to reset the local repo checkouts to the master working state
	./repo.sh reset

dev.up: | check-memory ## Bring up all services with host volumes
	docker-compose -f docker-compose.yml -f docker-compose-host.yml up -d
	@# Comment out this next line if you want to save some time and don't care about catalog programs
	./programs/provision.sh cache >/dev/null

dev.up.watchers: | check-memory ## Bring up asset watcher containers
	docker-compose -f docker-compose-watchers.yml up -d

dev.up.xqueue: | check-memory ## Bring up xqueue, assumes you already have lms running
	docker-compose -f docker-compose.yml -f docker-compose-xqueue.yml -f docker-compose-host.yml up -d

dev.up.all: | dev.up dev.up.watchers ## Bring up all services with host volumes, including watchers

dev.sync.daemon.start: ## Start the docker-sycn daemon
	docker-sync start

dev.sync.provision: | dev.sync.daemon.start dev.provision ## Provision with docker-sync enabled

dev.sync.requirements: ## Install requirements
	gem install docker-sync

dev.sync.up: dev.sync.daemon.start ## Bring up all services with docker-sync enabled
	docker-compose -f docker-compose.yml -f docker-compose-sync.yml up -d

provision: | dev.provision ## This command will be deprecated in a future release, use dev.provision
	echo "\033[0;31mThis command will be deprecated in a future release, use dev.provision\033[0m"

stop: ## Stop all services
	(test -d .docker-sync && docker-sync stop) || true ## Ignore failure here
	docker-compose stop

stop.watchers: ## Stop asset watchers
	docker-compose -f docker-compose-watchers.yml stop

stop.all: | stop.analytics_pipeline stop stop.watchers ## Stop all containers, including asset watchers

stop.xqueue:
	docker-compose -f docker-compose-xqueue.yml stop

down: ## Remove all service containers and networks
	(test -d .docker-sync && docker-sync clean) || true ## Ignore failure here
	docker-compose -f docker-compose.yml -f docker-compose-watchers.yml -f docker-compose-xqueue.yml -f docker-compose-analytics-pipeline.yml down

destroy: ## Remove all devstack-related containers, networks, and volumes
	./destroy.sh

logs: ## View logs from containers running in detached mode
	docker-compose -f docker-compose.yml -f docker-compose-analytics-pipeline.yml logs -f $*

%-logs: ## View the logs of the specified service container
	docker-compose -f docker-compose.yml -f docker-compose-analytics-pipeline.yml logs -f --tail=500 $*

xqueue-logs: ## View logs from containers running in detached mode
	docker-compose -f docker-compose-xqueue.yml logs -f xqueue

xqueue_consumer-logs: ## View logs from containers running in detached mode
	docker-compose -f docker-compose-xqueue.yml logs -f xqueue_consumer

pull: ## Update Docker images
	docker-compose pull --parallel

pull.xqueue: ## Update XQueue Docker images
	docker-compose -f docker-compose-xqueue.yml pull --parallel

validate: ## Validate the devstack configuration
	docker-compose config

backup: ## Write all data volumes to the host.
	docker run --rm --volumes-from $$(make -s dev.print-container.mysql) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zcvf /backup/mysql.tar.gz /var/lib/mysql
	docker run --rm --volumes-from $$(make -s dev.print-container.mongo) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zcvf /backup/mongo.tar.gz /data/db
	docker run --rm --volumes-from $$(make -s dev.print-container.elasticsearch) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zcvf /backup/elasticsearch.tar.gz /usr/share/elasticsearch/data

restore:  ## Restore all data volumes from the host. WARNING: THIS WILL OVERWRITE ALL EXISTING DATA!
	docker run --rm --volumes-from $$(make -s dev.print-container.mysql) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zxvf /backup/mysql.tar.gz
	docker run --rm --volumes-from $$(make -s dev.print-container.mongo) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zxvf /backup/mongo.tar.gz
	docker run --rm --volumes-from $$(make -s dev.print-container.elasticsearch) -v $$(pwd)/.dev/backups:/backup debian:jessie tar zxvf /backup/elasticsearch.tar.gz

# TODO: Print out help for this target. Even better if we can iterate over the
# services in docker-compose.yml, and print the actual service names.
%-shell: ## Run a shell on the specified service container
	docker-compose exec $* /bin/bash

credentials-shell: ## Run a shell on the credentials container
	docker-compose exec credentials env TERM=$(TERM) bash -c 'source /edx/app/credentials/credentials_env && cd /edx/app/credentials/credentials && /bin/bash'

discovery-shell: ## Run a shell on the discovery container
	docker-compose exec discovery env TERM=$(TERM) /edx/app/discovery/devstack.sh open

ecommerce-shell: ## Run a shell on the ecommerce container
	docker-compose exec ecommerce env TERM=$(TERM) /edx/app/ecommerce/devstack.sh open

e2e-shell: ## Start the end-to-end tests container with a shell
	docker run -it --network=${COMPOSE_PROJECT_NAME}_default -v ${DEVSTACK_WORKSPACE}/edx-e2e-tests:/edx-e2e-tests -v ${DEVSTACK_WORKSPACE}/edx-platform:/edx-e2e-tests/lib/edx-platform --env-file ${DEVSTACK_WORKSPACE}/edx-e2e-tests/devstack_env edxops/e2e env TERM=$(TERM) bash

%-update-db: ## Run migrations for the specified service container
	docker-compose exec $* bash -c 'source /edx/app/$*/$*_env && cd /edx/app/$*/$*/ && make migrate'

studio-update-db: ## Run migrations for the Studio container
	docker-compose exec studio bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform/ && paver update_db'

lms-update-db: ## Run migrations LMS container
	docker-compose exec lms bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform/ && paver update_db'

update-db: | studio-update-db lms-update-db discovery-update-db ecommerce-update-db credentials-update-db ## Run the migrations for all services

lms-shell: ## Run a shell on the LMS container
	docker-compose exec lms env TERM=$(TERM) /edx/app/edxapp/devstack.sh open

lms-watcher-shell: ## Run a shell on the LMS watcher container
	docker-compose exec lms_watcher env TERM=$(TERM) /edx/app/edxapp/devstack.sh open

%-attach: ## Attach to the specified service container process to use the debugger & see logs.
	docker attach "$$(make --silent dev.print-container.$*)"

lms-restart: ## Kill the LMS Django development server. The watcher process will restart it.
	docker-compose exec lms bash -c 'kill $$(ps aux | grep "manage.py lms" | egrep -v "while|grep" | awk "{print \$$2}")'

studio-shell: ## Run a shell on the Studio container
	docker-compose exec studio env TERM=$(TERM) /edx/app/edxapp/devstack.sh open

studio-watcher-shell: ## Run a shell on the studio watcher container
	docker-compose exec studio_watcher env TERM=$(TERM) /edx/app/edxapp/devstack.sh open

studio-restart: ## Kill the LMS Django development server. The watcher process will restart it.
	docker-compose exec studio bash -c 'kill $$(ps aux | grep "manage.py cms" | egrep -v "while|grep" | awk "{print \$$2}")'

xqueue-shell: ## Run a shell on the XQueue container
	docker-compose exec xqueue env TERM=$(TERM) /edx/app/xqueue/devstack.sh open

xqueue-restart: ## Kill the XQueue development server. The watcher process will restart it.
	docker-compose exec xqueue bash -c 'kill $$(ps aux | grep "manage.py runserver" | egrep -v "while|grep" | awk "{print \$$2}")'

xqueue_consumer-shell: ## Run a shell on the XQueue consumer container
	docker-compose exec xqueue_consumer env TERM=$(TERM) /edx/app/xqueue/devstack.sh open

xqueue_consumer-restart: ## Kill the XQueue development server. The watcher process will restart it.
	docker-compose exec xqueue_consumer bash -c 'kill $$(ps aux | grep "manage.py run_consumer" | egrep -v "while|grep" | awk "{print \$$2}")'

%-static: ## Rebuild static assets for the specified service container
	docker-compose exec $* bash -c 'source /edx/app/$*/$*_env && cd /edx/app/$*/$*/ && make static'

lms-static: ## Rebuild static assets for the LMS container
	docker-compose exec lms bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform/ && paver update_assets lms'

studio-static: ## Rebuild static assets for the Studio container
	docker-compose exec studio bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform/ && paver update_assets'

static: | credentials-static discovery-static ecommerce-static lms-static studio-static ## Rebuild static assets for all service containers

healthchecks: ## Run a curl against all services' healthcheck endpoints to make sure they are up. This will eventually be parameterized
	./healthchecks.sh

e2e-tests: ## Run the end-to-end tests against the service containers
	docker run -t --network=${COMPOSE_PROJECT_NAME:-devstack}_default -v ${DEVSTACK_WORKSPACE}/edx-e2e-tests:/edx-e2e-tests -v ${DEVSTACK_WORKSPACE}/edx-platform:/edx-e2e-tests/lib/edx-platform --env-file ${DEVSTACK_WORKSPACE}/edx-e2e-tests/devstack_env edxops/e2e env TERM=$(TERM)  bash -c 'paver e2e_test --exclude="whitelabel\|enterprise"'

validate-lms-volume: ## Validate that changes to the local workspace are reflected in the LMS container
	touch $(DEVSTACK_WORKSPACE)/edx-platform/testfile
	docker-compose exec -T lms ls /edx/app/edxapp/edx-platform/testfile
	rm $(DEVSTACK_WORKSPACE)/edx-platform/testfile

vnc-passwords: ## Get the VNC passwords for the Chrome and Firefox Selenium containers
	@docker-compose logs chrome 2>&1 | grep "VNC password" | tail -1
	@docker-compose logs firefox 2>&1 | grep "VNC password" | tail -1

devpi-password: ## Get the root devpi password for the devpi container
	docker-compose exec devpi bash -c "cat /data/server/.serverpassword"

mysql-shell: ## Run a shell on the mysql container
	docker-compose exec mysql bash

mysql-shell-edxapp: ## Run a mysql shell on the edxapp database
	docker-compose exec mysql bash -c "mysql edxapp"

mongo-shell: ## Run a shell on the mongo container
	docker-compose exec mongo bash

### analytics pipeline commands

dev.provision.analytics_pipeline: | check-memory dev.provision.analytics_pipeline.run stop.analytics_pipeline stop ## Provision analyticstack dev environment with all services stopped

dev.provision.analytics_pipeline.run:
	DOCKER_COMPOSE_FILES="-f docker-compose.yml -f docker-compose-host.yml -f docker-compose-analytics-pipeline.yml" ./provision-analytics-pipeline.sh

analytics-pipeline-shell: ## Run a shell on the analytics pipeline container
	docker-compose exec analytics_pipeline env TERM=$(TERM) /edx/app/analytics_pipeline/devstack.sh open

dev.up.analytics_pipeline: | check-memory ## Bring up analytics pipeline services
	docker-compose -f docker-compose.yml -f docker-compose-analytics-pipeline.yml -f docker-compose-host.yml up -d analyticspipeline

pull.analytics_pipeline: ## Update analytics pipeline docker images
	docker-compose -f docker-compose.yml -f docker-compose-analytics-pipeline.yml pull --parallel

analytics-pipeline-devstack-test: ## Run analytics pipeline tests in travis build
	docker-compose exec -u hadoop -T analyticspipeline bash -c 'sudo chown -R hadoop:hadoop /edx/app/analytics_pipeline && source /edx/app/hadoop/.bashrc && make develop-local && make docker-test-acceptance-local ONLY_TESTS=edx.analytics.tasks.tests.acceptance.test_internal_reporting_database && make docker-test-acceptance-local ONLY_TESTS=edx.analytics.tasks.tests.acceptance.test_user_activity'

stop.analytics_pipeline: ## Stop analytics pipeline services
	docker-compose -f docker-compose.yml -f docker-compose-analytics-pipeline.yml stop
	docker-compose up -d mysql      ## restart mysql as other containers need it

hadoop-application-logs-%: ## View hadoop logs by application Id
	docker-compose exec analytics_pipeline.nodemanager yarn logs -applicationId $*

# Provisions studio, ecommerce, and marketing with course(s) in test-course.json
# Modify test-course.json before running this make target to generate a custom course
create-test-course: ## NOTE: marketing course creation is not available for those outside edX
	./course-generator/create-courses.sh --studio --ecommerce --marketing course-generator/test-course.json

# Run the course json builder script and use the outputted course json to provision studio, ecommerce, and marketing
# Modify the list of courses in build-course-json.sh beforehand to generate custom courses
build-courses: ## NOTE: marketing course creation is not available for those outside edX
	./course-generator/build-course-json.sh course-generator/tmp-config.json
	./course-generator/create-courses.sh --studio --ecommerce --marketing course-generator/tmp-config.json
	rm course-generator/tmp-config.json

check-memory: ## Check if enough memory has been allocated to Docker
	@if [ `docker info --format '{{json .}}' | python -c "from __future__ import print_function; import sys, json; print(json.load(sys.stdin)['MemTotal'])"` -lt 2095771648 ]; then echo "\033[0;31mWarning, System Memory is set too low!!! Increase Docker memory to be at least 2 Gigs\033[0m"; fi || exit 0

stats: ## Get per-container CPU and memory utilization data
	docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

studio-reindex-courses: ## Rebuild static assets for the Studio container
	docker-compose exec studio bash -c 'echo y | /edx/app/edxapp/venvs/edxapp/bin/python /edx/app/edxapp/edx-platform/manage.py cms reindex_course --all --settings devstack_docker; echo y | /edx/app/edxapp/venvs/edxapp/bin/python /edx/app/edxapp/edx-platform/manage.py cms reindex_library --all --settings devstack_docker'
