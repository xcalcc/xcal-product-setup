#!/bin/bash

# ---------------------------------------------------------------------
#       Xcalscan Server Service Switch
# ---------------------------------------------------------------------

PRODUCT_NAME="xcalscan"
PRODUCT_VERSION=PRODUCT_RELEASE_VERSION
CONVERTED_PRODUCT_VERSION=$(echo ${PRODUCT_VERSION} | tr "." "-")
NETWORK_SUFFIX="$(echo $PRODUCT_VERSION | tr "." "_")"
SITE_COMPOSE_FILE=$2
FILE_NAME=`basename $0`
PRODUCT_NAME=${PRODUCT_NAME}-${CONVERTED_PRODUCT_VERSION}
INSTALL_PREFIX=XCAL_INSTALL_PREFIX
CMD_PREFIX=""

WARN="[Warning]:"
ERR="[Error]:"
INFO="[Info]:"

usage(){
  echo "Usage:"
  echo "${FILE_NAME} <start|stop|restart|update> <compose-file>"
  echo "  use 'compose-file' for ${PRODUCT_NAME} configuration compose-file."
  echo ""
}

# --------------------------------------------------------------------- #
#  Return code verification
# --------------------------------------------------------------------- #
status_check() {
  ret=$1
  prompt=$2

  if [ ${ret} != 0 ]; then
    echo "${ERR} ${prompt}...failed"
    exit 1
  else
    echo "${INFO} ${prompt}...ok"
  fi
}

# --------------------------------------------------------------------- #
#  Enable docker commands execution if user not in docker group
# --------------------------------------------------------------------- #
id_identification() {
  if [ "$(docker info 2>&1 | grep "permission denied")" ]; then
    echo "${INFO} Please grant sudo to execute docker commands."
    CMD_PREFIX="sudo "
  fi
}

# --------------------------------------------------------------------- #
#  Check docker daemon
# --------------------------------------------------------------------- #
dependency_check() {
  echo "${INFO} Detecting if docker installed..."
  if [ ! $(command -v docker) ]; then
    echo "${ERR} Detecting if docker installed...failed"
    echo "${ERR} ${PRODUCT_NAME} installer requires docker to be installed, please install first!"
    exit 1
  fi
  echo "${INFO} Detecting if docker installed...ok"

  echo "${INFO} Detecting if docker in running status..."
  docker_status_check=$(${CMD_PREFIX} docker info 2>&1 | grep "Is the docker daemon running")
  if [ x"${docker_status_check}" != x"" ]; then
    echo "${ERR} Detecting if docker in running status...failed"
    echo "${ERR} Docker daemon is not running, please run it first"
    exit 1
  fi
  echo "${INFO} Detecting if docker in running status...ok"
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_stack() {
  echo "${INFO} Removing ${PRODUCT_NAME} services, please wait..."
  ${CMD_PREFIX} docker stack rm ${PRODUCT_NAME} &&
    sleep 30
  if [ $? != 0 ]; then
     echo "${ERR} Removing ${PRODUCT_NAME} services, please wait...failed"
     exit 1
  else
     echo "${INFO} Removing ${PRODUCT_NAME} services, please wait...ok"
  fi

  echo "${INFO} Removing ${PRODUCT_NAME} network, please wait..."
  if [ "$(${CMD_PREFIX} docker network ls | grep xcal_wsnet_${NETWORK_SUFFIX})"x != ""x ]; then
    ${CMD_PREFIX} docker network rm xcal_wsnet_${NETWORK_SUFFIX} >/dev/null 2>&1
  fi
  if [ $? != 0 ]; then
     echo "${ERR} Removing ${PRODUCT_NAME} network, please wait...failed"
     exit 2
  else
     echo "${INFO} Removing ${PRODUCT_NAME} network, please wait...ok"
  fi

  echo "${INFO} Removing ${PRODUCT_NAME} exited container, please wait..."
  exited_container=$(${CMD_PREFIX} docker ps -a -f status=exited | grep "xcal." | awk '{print $1}')
  if [ "${exited_container}"x != ""x ]; then
    ${CMD_PREFIX} docker rm ${exited_container} > /dev/null 2>&1
    status_check $? "Removing ${PRODUCT_NAME} exited container, please wait..."
  else
    echo "${INFO} No exited container(s), skip removal."
  fi
  echo ""
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
update_stack() {
  echo "${INFO} Updating ${PRODUCT_NAME} services, please wait..."
  if [[ -z "${SITE_COMPOSE_FILE}" || ! -f "${SITE_COMPOSE_FILE}" ]]; then
    SITE_COMPOSE_FILE=${INSTALL_PREFIX}/xcalibyte/xcalscan/${PRODUCT_VERSION}/config/site.xcalscan-${PRODUCT_VERSION}-docker-compose-customer.yml
    echo "${INFO} No compose file specified, using default compose file:${SITE_COMPOSE_FILE}"
  fi
  ${CMD_PREFIX} env $(cat ${INSTALL_PREFIX}/.env | grep ^[A-Z] | xargs) docker stack deploy -c ${SITE_COMPOSE_FILE} ${PRODUCT_NAME}
  status_check $? "Updating ${PRODUCT_NAME} services, please wait"
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
start_stack(){
  if [[ -z "${SITE_COMPOSE_FILE}" || ! -f "${SITE_COMPOSE_FILE}" ]]; then
    SITE_COMPOSE_FILE=${INSTALL_PREFIX}/xcalibyte/xcalscan/${PRODUCT_VERSION}/config/site.xcalscan-${PRODUCT_VERSION}-docker-compose-customer.yml
    echo "${INFO} No compose file specified, using default compose file:${SITE_COMPOSE_FILE}"
  fi  
  echo "${INFO} Establishing ${PRODUCT_NAME} network xcal_wsnet_${NETWORK_SUFFIX}, please wait..."
  ${CMD_PREFIX} docker network create -d overlay --attachable xcal_wsnet_${NETWORK_SUFFIX}
  status_check $? "Establishing ${PRODUCT_NAME} network xcal_wsnet_${NETWORK_SUFFIX}, please wait"

  echo "${INFO} Deploying ${PRODUCT_NAME} services, please wait..."

  ${CMD_PREFIX} env $(cat ${INSTALL_PREFIX}/.env | grep ^[A-Z] | xargs) docker stack deploy -c ${SITE_COMPOSE_FILE} ${PRODUCT_NAME}
  status_check $? "Deploying ${PRODUCT_NAME} services, please wait"

  #Preparation for Kafka
  ret=1
  until [ $ret -eq 0 ]; do
    echo "Checking if Kafka is ready"
    new_kafka_id=`${CMD_PREFIX} docker ps -qf "name=^xcalscan-"$PRODUCT_VERSION"_kafka"`
    if [ ! -z "$new_kafka_id" ]; then
      sudo docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --version"
      ret=$?
    fi
    sleep 15
  done
  ${CMD_PREFIX}  docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --create --topic job-scan-engine-runner --zookeeper zookeeper:2181   --partitions 3 --replication-factor 1" > /dev/null 2>&1
  number_of_partitions=$(docker exec $new_kafka_id /bin/bash -c "/opt/kafka/bin/kafka-topics.sh --describe --zookeeper zookeeper:2181 --topic job-scan-engine-runner | awk '{print \$2}' | uniq -c | awk 'NR==2{print \$1}'")
  if [[ "$number_of_partitions" -ne 3 ]]; then
    ${CMD_PREFIX} docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper:2181 --alter --topic job-scan-engine-runner --partitions 3"
  else
    echo "topic partitions has set to 3 already"
  fi

  echo "${INFO} Service for ${PRODUCT_NAME} started successfully. "
  echo ""
}

# --------------------------------------------------------------------- #
#  Option handling
# --------------------------------------------------------------------- #
if [ $# -eq 0 ]; then
  usage
  exit 1
fi
until [ $# -eq 0 ]; do
  dependency_check
  id_identification
  case "$1" in
    start)
    start_stack    
    break
      ;;
    stop)
    remove_stack
    break
      ;;
    restart)
    remove_stack    
    start_stack    
    break
      ;;
    update)
    update_stack
    break
      ;;
    *)
    echo "${ERR} ${FILE_NAME} NOT support $1!"
    exit 1
      ;;
  esac
done

if [ $? != 0 ]; then
  echo "${ERR} ${FILE_NAME} $1 failed. Please retry."
else
  echo "${INFO} ${FILE_NAME} $1 successfully. "
  echo ""
  exit 0
fi
