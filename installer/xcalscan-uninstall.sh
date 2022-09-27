#!/bin/bash

# ---------------------------------------------------------------------
#       Xcalscan Server Uninstallation Script
# ---------------------------------------------------------------------

COMPANY="xcalibyte"
PRODUCT_NAME="Xcalibyte-XcalScan"
PRODUCT=PRODUCT_RELEASE_NAME
PRODUCT_VERSION=PRODUCT_RELEASE_VERSION
NETWORK_SUFFIX="$(echo $PRODUCT_VERSION | tr "." "_")"
#PRODUCT=xcalscan
#PRODUCT_VERSION=WithWS-c
PRODUCT_FILE_NAME=${COMPANY}-${PRODUCT}-${PRODUCT_VERSION}
CONVERTED_PRODUCT_VERSION=$(echo ${PRODUCT_VERSION} | tr "." "-")
PRODUCT_STACK_NAME="${PRODUCT}-${CONVERTED_PRODUCT_VERSION}"
PRODUCT_NETWORK=xcal_wsnet_${NETWORK_SUFFIX}
SITE_COMPOSE_FILE=config/site.${PRODUCT}-${PRODUCT_VERSION}-docker-compose-customer.yml
INSTALL_PREFIX=XCAL_INSTALL_PREFIX


CMD_PREFIX=""
LOG_FILE="${INSTALL_PREFIX}/xcal_uninstall.log"

WARN="[Warning]:"
ERR="[Error]:"
INFO="[Info]:"

if_leave=""
if_delete=""

# --------------------------------------------------------------------- #
# Logger
# --------------------------------------------------------------------- #
logger() {
  lv=$1
  msg=$2

  echo "${lv} ${msg}"
  echo "${lv} ${msg}" >>${LOG_FILE}
}

# --------------------------------------------------------------------- #
# Check return code
# --------------------------------------------------------------------- #
status_check() {
  ret=$1
  msg=$2

  if [ ${ret} != 0 ]; then
    logger ${ERR} "${msg}...failed"
    logger ${ERR} "Removing ${PRODUCT_NAME}:${PRODUCT_VERSION} from your system...failed"
    exit 1
  else
    logger "${INFO} ${msg}...ok"
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
start_banner() {
  logger "${INFO} Removing ${PRODUCT_NAME}:${PRODUCT_VERSION} from your system..."
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
id_identification() {
  if [ "$(docker info 2>&1 | grep "permission denied")" ]; then
    echo "${INFO} Please grant sudo to execute docker commands."
    CMD_PREFIX="sudo "
  fi
}

# --------------------------------------------------------------------- #
# Change to install directory
# --------------------------------------------------------------------- #
change_directory() {
  logger ${INFO} "Changing directory to ${INSTALL_PREFIX}"
  status_check $? "Changing directory to ${INSTALL_PREFIX}"
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
dependency_check() {
#check docker
  logger ${INFO} "Detecting if docker installed..."
  if [ ! $(command -v docker) ]; then
    logger ${ERR} "Detecting if docker installed...failed"
    logger ${ERR} "${PRODUCT_NAME} installer requires docker to be installed, please install first!"
    exit 1
  fi
  logger ${INFO} "Detecting if docker installed...ok"

  logger ${INFO} "Detecting if docker in running status..."
  docker_status_check=`${CMD_PREFIX} docker info 2>&1 | grep "Is the docker daemon running"`
  if [ x"${docker_status_check}" != x"" ]; then
     logger ${ERR} "Detecting if docker in running status...failed"
     logger ${ERR} "Docker daemon is not running, please run it first"
     exit 1
  fi
  logger ${INFO} "Detecting if docker in running status...ok"
}

# --------------------------------------------------------------------- #
#  Make sure xvsa container is not running
# --------------------------------------------------------------------- #
check_if_scanning() {
  if_processing_scan=$(docker ps 2>&1 | grep xvsa)
  if [ "${if_processing_scan}"x != ""x ]; then
    logger ${ERR} "Scanning process dectected, please make sure there is no active scan process."
    exit 1
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_monitor_related_containers() {
  MONITOR_SERVER_OPTION=$(cat ${INSTALL_PREFIX}/.env | grep "MONITOR_SERVER_OPTION" | tr "=" " " | awk '{print $2}')
  logger ${INFO} "Removing monitor related containers"
  if [ "${MONITOR_SERVER_OPTION}"x = "on"x ]; then
    if [ "$(${CMD_PREFIX} docker ps 2>&1 | grep "xcal_node-exporter")" ]; then
      ${CMD_PREFIX} docker rm -f xcal_node-exporter_${PRODUCT_VERSION} >>${LOG_FILE} 2>&1
      status_check $? "Removing monitor related container:xcal_node-exporter"
    else
      logger ${INFO} "Monitor related container:xcal_node-exporter not found.  Skip."
    fi
    if [ "$(${CMD_PREFIX} docker ps 2>&1 | grep "xcal_cadvisor")" ]; then
      ${CMD_PREFIX} docker rm -f xcal_cadvisor_${PRODUCT_VERSION} >>${LOG_FILE} 2>&1
      status_check $? "Removing monitor related container:xcal_cadvisor"
    else
      logger ${INFO} "Monitor related container:xcal_cadvisor not found.  Skip."
    fi
  elif [ "${MONITOR_SERVER_OPTION}"x = "off"x ]; then
    logger ${INFO} "MONITOR_SERVER_OPTION off.  Skip"
  else
    return  # TODO
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_stack() {
  find_stack=$(${CMD_PREFIX} docker stack ls | grep ${PRODUCT_STACK_NAME})
  if [ "${find_stack}"x != ""x ]; then
     logger ${INFO} "Removing ${PRODUCT_STACK_NAME} docker stack..."
     ${CMD_PREFIX} docker stack rm ${PRODUCT_STACK_NAME}
     status_check $? "Removing ${PRODUCT_STACK_NAME} docker stack"

     logger ${INFO} "Waiting for services to be removed..."
     sleep 60
  else
     logger ${INFO} "Skip ${PRODUCT_STACK_NAME} docker stack removal."
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_exited_containers(){
  logger ${INFO} "Removing ${PRODUCT_STACK_NAME} exited container..."
  exited_container=$(${CMD_PREFIX} docker ps -a -f status=exited | grep "xcal." | awk '{print $1}')
  if [ "${exited_container}" != "" ]; then
    ${CMD_PREFIX} docker rm ${exited_container} > ${LOG_FILE} 2>&1
    if [ $? != 0 ]; then
      logger ${ERR} "Removing ${PRODUCT_STACK_NAME} exited container...failed"
    else
      logger ${INFO} "Removing ${PRODUCT_STACK_NAME} exited container...ok"
    fi
  else
    logger ${INFO} "No exited container(s), skip removal."
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
read_used_images() {
  logger ${INFO} "Finding images being used..."
#  used_images=`cat ${PRODUCT_INSTALL_ROOT}'/'${SITE_COMPOSE_FILE} | grep image | tr ":" " " | awk '{print $2":"$3}'`
  used_images=`${CMD_PREFIX} docker image ls 2>&1 | grep xcal | grep ${PRODUCT_VERSION} | awk '{print $1":"$2}'`
  status_check $? "Finding images being used"

  logger ${INFO} "Images being used as below:"
  for used_image in ${used_images}
  do
    logger "" ${used_image}
  done
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
image_find_result="no"
check_image_exist() {
   image_name=$1

   if [ "${image_name}"x = ""x ]; then
     logger ${ERR} "image name can't be null."
     exit 1
   fi
   repository=`echo ${image_name} | tr ":" " " | awk '{print $1}'`
   tag=`echo ${image_name} | tr ":" " " | awk '{print $2}'`

   image_find_result="no"
   logger ${INFO} "Finding image: ${image_name}..."
   find_image_res=`${CMD_PREFIX} docker image ls 2>&1 | grep ${repository} | grep ${tag}`
#   status_check $? "Finding image: ${image_name}"

   if [ "${find_image_res}"x != ""x ]; then
     image_find_result="yes"
   fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_images() {
  logger ${INFO} "Removing used images..."
  for used_image in ${used_images}
  do
    check_image_exist ${used_image}
    if [ "${image_find_result}"x = "yes"x ]; then
      logger ${INFO} "Removing ${used_image}"
      ${CMD_PREFIX} docker rmi -f ${used_image}

      status_check $? "Removing ${used_image}"
    else
      logger ${INFO} "${used_image} not found. Skip removing."
    fi
  done
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_volume() {
  logger ${INFO} "Finding used docker volumes..."
  volumes_find_res=`${CMD_PREFIX} docker volume ls 2>&1 | grep ${PRODUCT_STACK_NAME} | awk '{print $2}'`
  status_check $? "Finding used docker volumes..."
  if [ "${volumes_find_res}"x != ""x ]; then
    if_keep=""
    if [ "${if_delete}"x = "y"x ]; then
      if_keep="n"
    else
      if_keep="n"
      # while [ "${if_keep}"x = ""x ]; do
      #   read -p "${WARN} Please confirm if keep current volumes. (y/n): " if_keep
      #   if [[ "${if_keep}"x = "y"x || "${if_keep}"x = "n"x ]]; then
      #     break
      #   else 
      #     if_keep=""
      #   fi
      # done
    fi
    if [ "${if_keep}"x != "y"x ]; then
      for volume in ${volumes_find_res}
      do
        logger ${INFO} "Removing used docker volume ${volume}..."
        ${CMD_PREFIX} docker volume rm ${volume} > ${LOG_FILE}
        status_check $? "Removing used docker volume ${volume}"
      done
    else
      logger ${INFO} "Keep current volumes."
    fi
  else
    logger ${INFO} "No used volumes found.  Skip."
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
remove_network() {
   logger ${INFO} "Finding used docker network..."
   network_find_res=`${CMD_PREFIX} docker network ls 2>&1 | grep ${PRODUCT_NETWORK} | awk '{print $2}'`
   status_check $? "Finding used docker network"

   if [ "${network_find_res}"x != ""x ]; then
     echo ${INFO} "Removing used docker network ${network_find_res}..."
     ${CMD_PREFIX} docker network rm ${network_find_res} > ${LOG_FILE}
     status_check $? "Removing used docker network ${network_find_res}"
   else
     logger ${INFO} "No used network found.  Skip."
   fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
leave_docker_swarm() {
  logger ${INFO} "Leaving docker swarm..."

  in_swarm=""
  if [ "$(${CMD_PREFIX} docker info 2>&1 | grep "Swarm" | tr ':' ' ' | awk '{print $2}' )" = "inactive" ]; then
    in_swarm="false"
  else
    in_swarm="true"
  fi

  if [ "${in_swarm}"x = "true"x ]; then

    while [ "${if_leave}"x = ""x ]; do
      read -p "${WARN} Please confirm that you wish to leave the current docker swarm.(y/n): " if_leave
      if [[ "${if_leave}" = "y" || "${if_leave}" = "n" ]]; then
         break
      fi
    done

    if [ "${if_leave}"x = "y"x ]; then
      ${CMD_PREFIX} docker swarm leave -f > ${LOG_FILE} 2>&1
      status_check $? "Leaving docker swarm"
    else
      logger ${INFO} "Skip leaving docker swarm."
    fi
  else
    logger ${INFO} "Not in docker swarm.  Skip."
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
clean_up_all_files() {
#  change_directory
  logger ${INFO} "Removing xcalscan files..."

  while [ "${if_delete}"x = ""x ]; do
      read -p "${WARN} Please confirm that you wish to erase the current directory:
      ${INSTALL_PREFIX} (y/n): " if_delete

      if [[ "${if_delete}"x = "y"x || "${if_delete}"x = "n"x ]]; then
         break
      fi
  done

  if [ "${if_delete}"x = "y"x ]; then
    logger ${WARN} "Erasing current directory: ${INSTALL_PREFIX}..."
    rm -f ${INSTALL_PREFIX}/.env ${INSTALL_PREFIX}/.env.bak && \
    rm -f ${INSTALL_PREFIX}/VER.txt ${INSTALL_PREFIX}/${PRODUCT}-${PRODUCT_VERSION}-install.sh ${INSTALL_PREFIX}/${PRODUCT}-${PRODUCT_VERSION}-uninstall.sh ${INSTALL_PREFIX}/xcalscan-service.sh ${INSTALL_PREFIX}/xcal_install.log ${INSTALL_PREFIX}/upgrade.sh && \
    rm -f ${INSTALL_PREFIX}/${COMPANY}-${PRODUCT}-${PRODUCT_VERSION}*.tar ${INSTALL_PREFIX}/${COMPANY}-${PRODUCT}-${PRODUCT_VERSION}*.tar.gz && \
    sudo rm -rf ${INSTALL_PREFIX}/${COMPANY}/${PRODUCT}/${PRODUCT_VERSION}/config
    sudo rm -rf ${INSTALL_PREFIX}/${COMPANY}/${PRODUCT}/${PRODUCT_VERSION}/images
    status_check $? "Erasing current directory: ${INSTALL_PREFIX}"
  else
    logger ${INFO} "Skip files erasing."
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
end_banner() {
  logger ${INFO} "Removing ${PRODUCT_NAME}:${PRODUCT_VERSION} from your system...ok"
  rm ${LOG_FILE}  ## Remove uninstall log if succeed in uninstalling
  exit 0
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
uninstall() {
  start_banner
  dependency_check
  id_identification
  check_if_scanning
  remove_monitor_related_containers
  remove_stack
  remove_exited_containers
  read_used_images
  remove_images
  remove_network
  leave_docker_swarm
  clean_up_all_files
  end_banner
}


while "true"; do
  if [ $# -eq 0 ]; then
    break
  fi

  case "${1}" in
  -l|--leaveswarm)
    shift
    if [ "${1}"x = "n"x -o "${1}"x = "y"x ]; then
      if_leave=${1}
    else
      echo "${ERR} Unknown value \"${1}\" for LeaveSwarm."
      if_leave=""
    fi
    shift
    ;;
  -c|--cleanall)
    shift
    if [ "${1}"x = "n"x -o "${1}"x = "y"x ]; then
      if_delete=${1}
    else
      echo "${ERR} Unknown value \"${1}\" for CleanAll."
      if_delete=""
    fi
    shift
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "${ERR} Unknown Option:${1}"
    exit 1
    ;;
  esac
done

uninstall

