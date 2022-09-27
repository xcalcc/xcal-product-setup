#!/bin/bash

# ---------------------------------------------------------------------
#          Xcalscan Server Installation Script
# ---------------------------------------------------------------------

COMPANY="xcalibyte"
#PRODUCT=xcalscan
#PRODUCT_NAME="Xcalibyte-XcalScan"
#PRODUCT_VERSION=POC1-0-9
PRODUCT=PRODUCT_RELEASE_NAME
PRODUCT_NAME="XcalScan"
PRODUCT_VERSION=PRODUCT_RELEASE_VERSION
NETWORK_SUFFIX="$(echo $PRODUCT_VERSION | tr "." "_")"
PRODUCT_FILE_NAME=${COMPANY}-${PRODUCT}-${PRODUCT_VERSION}
PRODUCT_INSTALLER_TARBALL=${PRODUCT_FILE_NAME}-installer.tar.gz
PRODUCT_TARBALL=${PRODUCT_FILE_NAME}.tar
PRODUCT_IMAGES=xcal.images.tar
PRODUCT_INSTALL_ROOT=${COMPANY}/${PRODUCT}/${PRODUCT_VERSION}
PRODUCT_COMPOSE_FILE=config/${PRODUCT}-${PRODUCT_VERSION}-docker-compose-customer.yml
SITE_COMPOSE_FILE=config/site.${PRODUCT}-${PRODUCT_VERSION}-docker-compose-customer.yml
DEFAULT_INSTALL_PREFIX=$(pwd)
INSTALL_PREFIX=""
CMD_PREFIX=""
KERNEL_NAME=""
MONITOR_SERVER_OPTION=""
OS_ID=""
LOG_FILE="${DEFAULT_INSTALL_PREFIX}/xcal_install.log"

WARN="[Warning]:"
ERR="[Error]:"
INFO="[Info]:"

IS_CONFIGURATION_CONFIRMED=""
DB_PW="Default_Password"

EXISTINGVERS="no"
VOLUME_NAME="_redisdata"
if_use="no"
if_match=""
converted_product_version=""
REUSE_DATA=""
re='^(0*(1?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))\.){3}'
re+='0*(1?[0-9]{1,2}|2([‌0-4][0-9]|5[0-5]))$'



# --------------------------------------------------------------------- #
# Logger
# --------------------------------------------------------------------- #
logger() {
  lv=$1
  msg=$2

  echo "${lv} ${msg}"
  echo "${lv} ${msg}" >>${LOG_FILE}
}

logger_without_prompt() {
  lv=$1
  msg=$2

  echo "${lv} ${msg}" >>${LOG_FILE}
}

# --------------------------------------------------------------------- #
#  Return code verification
# --------------------------------------------------------------------- #
status_check() {
  ret=$1
  prompt=$2

  if [ ${ret} != 0 ]; then
    logger ${ERR} "${prompt}...failed"
    logger ${ERR} "Installing ${PRODUCT_NAME}:${PRODUCT_VERSION} into your system...failed"
    exit 1
  else
    logger ${INFO} "${prompt}...ok"
  fi
}

# --------------------------------------------------------------------- #
#  Environment variable substitution
# --------------------------------------------------------------------- #
env_substitute() {
  var_name=$1
  var_value=$2

  if [ -z "$(cat ${INSTALL_PREFIX}/.env | grep ${var_name})" ]; then
    logger ${INFO} "Adding env variable ${var_name}."
    echo "${var_name}=${var_value}" >>${INSTALL_PREFIX}/.env
  else
    logger ${INFO} "Updating env variable ${var_name}."
    pre_value=$(cat ${INSTALL_PREFIX}/.env | grep ${var_name} | tr "=" " " | awk '{print $2}')
    sed -i.bak "s#${var_name}=${pre_value}#${var_name}=${var_value}#g" "${INSTALL_PREFIX}/.env"
  fi
}

# --------------------------------------------------------------------- #
#  Check if port is occupied
# --------------------------------------------------------------------- #
PORT_USAGE="true"

detect_if_port_in_use() {
  port=$1
  port_type=$2
  port_for=$3 ## Optional: what the port use for

  if [ "${port}" = "" ]; then
    logger ${WARN} "Port for ${port_for} is not specified, will use available port."
    PORT_USAGE="false"
    return
  fi
  logger ${INFO} "Checking ${port_type} port ${port} for ${port_for}..."
  PORT_USAGE="true"
  pattern=""
  pre_cmd=""

  if [ "${KERNEL_NAME}" = "Darwin" ]; then # OSX
    pre_cmd="netstat -vanp "
    pattern="\."
  elif [ "${KERNEL_NAME}" = "Linux" ]; then # Linux
    pre_cmd="netstat -van --"
    pattern=":"
  else
    logger ${ERR} "Kernel type not supported for checking port."
    return # FIXME: Is it a good implementation?
  fi

  netstat_cmd=""
  if [ "${port_type}" = "UDP" ]; then
    netstat_cmd="${CMD_PREFIX} ${pre_cmd}udp | awk '{print \$4}' | grep \"${pattern}${port}$\""

    if [ ! "$(bash -c "${netstat_cmd}")" ]; then
      PORT_USAGE="false"
      logger ${INFO} "${port_type} port ${port} for ${port_for} is not in use."
    else
      logger ${ERR} "${port_type} port ${port} for ${port_for} is in use."
    fi
  elif [ "${port_type}" = "TCP" ]; then
    netstat_cmd="${CMD_PREFIX} ${pre_cmd}tcp  | grep LISTEN | awk '{print \$4}' | grep \"${pattern}${port}$\""

    if [ ! "$(bash -c "${netstat_cmd}")" ]; then
      PORT_USAGE="false"
      logger ${INFO} "${port_type} port ${port} for ${port_for} is not in use."
    else
      logger ${ERR} "${port_type} port ${port} for ${port_for} is in use."
    fi
  else
    logger ${ERR} "Port protocol not supported"
    exit 1
  fi
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
start_banner() {
  logger ${INFO} "Installing ${PRODUCT_NAME}:${PRODUCT_VERSION} into your system..."
}

# --------------------------------------------------------------------- #
#  Find the operating system
# --------------------------------------------------------------------- #
os_identification() {
  logger ${INFO} "Identifying working OS..."
  KERNEL_NAME=$(uname -s)
  if [ "${KERNEL_NAME}"x = "Darwin"x ]; then
    OS_ID="macos"
    logger ${INFO} "OS: ${KERNEL_NAME}, ${OS_ID}"
  elif [ "${KERNEL_NAME}"x = "Linux"x ]; then
    OS_ID=$(cat /etc/os-release | grep "^ID=" | tr "=" " " | tr -d "\"" | awk '{print $2}')
    logger ${INFO} "OS: ${KERNEL_NAME}, ${OS_ID}"
  #TODO: Find if other kernel
  else
    logger ${ERR} "OS cannot be identified currently."
    exit 1
  fi
}

# --------------------------------------------------------------------- #
#  Enable docker commands execution if user not in docker group
# --------------------------------------------------------------------- #
id_identification() {
  if [ "$(docker info 2>&1 | grep "permission denied")" ]; then
    logger ${INFO} "Please grant sudo to execute docker commands."
    CMD_PREFIX="sudo "
  fi
}

# --------------------------------------------------------------------- #
# Memory Check
# --------------------------------------------------------------------- #
memory_check() {
  minimum_memory_kb=4194304 ## 4G
  logger ${INFO} "Minimum memory requested is ${minimum_memory_kb}kB."
  if [ "${KERNEL_NAME}"x = "Darwin"x ]; then
    current_memory_total_kb=$(($(sysctl hw.memsize | awk '{print $2}') / 1024))
  elif [ "${KERNEL_NAME}"x = "Linux"x ]; then
    current_memory_total_kb=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  else
    logger ${ERR} "Unble to detect if memory sufficient for current OS:${KERNEL_NAME}."
    exit 1
  fi

  logger ${INFO} "Current memory total is ${current_memory_total_kb}kB."
  if [ ${current_memory_total_kb} -lt ${minimum_memory_kb} ]; then
    logger ${ERR} "Memory not sufficient, installation aborted."
    exit 1
  else
    logger ${INFO} "Memory check passed."
  fi
}

# --------------------------------------------------------------------- #
# Disk Check
# --------------------------------------------------------------------- #
disk_space_check() {
  logger $INFO "Checking disk space."
  if [ ! -f "${PRODUCT_INSTALLER_TARBALL}" ]; then
    logger $WARN "Missing ${PRODUCT_INSTALLER_TARBALL}, could not check whether disk space is sufficient."
    return
  fi
  if [ $(command -v gzip) ]; then
    extracted_size_kb=$(($(gzip -l "${PRODUCT_INSTALLER_TARBALL}" | sed -n 2p | awk '{print $2}') / 1024))
  else
    logger $INFO "Missing gzip, using tar."
    extracted_size_kb=$(($(tar -xzf "${PRODUCT_INSTALLER_TARBALL}" --to-stdout | wc -c) / 1024))
  fi
  logger ${INFO} "Extracted tarball size would be ${extracted_size_kb}kB."

  disks=$(df -k | tr " " "_")
  for disk in ${disks[@]}; do
    disk=$(echo $disk | tr "_" " ")
    mount_point=$(echo $disk | awk '{print $NF}')
    if [ "${mount_point}"x = "/"x ]; then
      current_disk_avail=$(echo $disk | awk '{print $4}')
      logger ${INFO} "Current available disk is: ${current_disk_avail}kB"
    fi
  done

  if [ ${extracted_size_kb} -gt ${current_disk_avail} ]; then
    logger ${ERR} "Disk space not sufficient, installation aborted."
    exit 1
  else
    logger ${INFO} "Disk space check passed."
  fi
}

# --------------------------------------------------------------------- #
#  Check docker daemon
# --------------------------------------------------------------------- #
dependency_check() {

  logger ${INFO} "Detecting if docker installed..."
  if [ ! $(command -v docker) ]; then
    logger ${ERR} "Detecting if docker installed...failed"
    logger ${ERR} "${PRODUCT_NAME} installer requires docker to be installed, please install first!"
    exit 1
  fi
  logger ${INFO} "Detecting if docker installed...ok"

  logger ${INFO} "Detecting if docker in running status..."
  docker_status_check=$(${CMD_PREFIX} docker info 2>&1 | grep "Is the docker daemon running")
  if [ x"${docker_status_check}" != x"" ]; then
    logger ${ERR} "Detecting if docker in running status...failed"
    logger ${ERR} "Docker daemon is not running, please run it first"
    exit 1
  fi
  logger ${INFO} "Detecting if docker in running status...ok"

  logger ${INFO} "Detecting if netstat installed..."
  if [ ! $(command -v netstat) ]; then
    logger ${ERR} "Detecting if netstat installed...failed"
    logger ${ERR} "${PRODUCT_NAME} installer requires netstat to be installed, please install first!"
    exit 1
  fi
  logger ${INFO} "Detecting if netstat installed...ok"
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
pre_verification() {
  # TODO: shasum check
  logger ${INFO} "Verifying ${PRODUCT_NAME} installer..."

  if [ ! -f "${PRODUCT_TARBALL}" ]; then
    logger ${ERR} "${PRODUCT_NAME} installer data:${PRODUCT_TARBALL} NOT in current directory $(pwd)"
    exit 1
  fi
}

# --------------------------------------------------------------------- #
# Ports checker
# --------------------------------------------------------------------- #
ports_checker() {
  tcp_ports=$(cat ${INSTALL_PREFIX}/.env | grep "PORT" | grep "TCP")
  udp_ports=$(cat ${INSTALL_PREFIX}/.env | grep "PORT" | grep "UDP")

  logger ${INFO} "Checking if tcp ports available..."
  for tcp_port in ${tcp_ports[@]}; do
    if [ "$(echo $tcp_port | grep '^MONITOR')"x != ""x ]; then
      continue
    fi
    t_port_name=$(echo ${tcp_port} | tr "=" " " | awk '{print $1}')
    t_port_value=$(echo ${tcp_port} | tr "=" " " | awk '{print $2}')

    t_new_port_value=${t_port_value}
    while "true"; do
      detect_if_port_in_use "${t_new_port_value}" "TCP" ${t_port_name}
      if [ "${PORT_USAGE}"x = "false"x ]; then
        break
      fi
      read -p "${ERR} TCP port ${t_new_port_value} for ${t_port_name} is being used, please type another port: " t_new_port_value
    done
    if [ "${t_new_port_value}"x != "${t_port_value}"x ]; then
      env_substitute ${t_port_name} ${t_new_port_value}
    fi
  done
  logger ${INFO} "Checking if tcp ports available...ok"

  logger ${INFO} "Checking if udp ports available..."
  for udp_port in ${udp_ports[@]}; do
    if [ "$(echo $udp_port | grep '^MONITOR')"x != ""x ]; then
      continue
    fi
    u_port_name=$(echo ${udp_port} | tr "=" " " | awk '{print $1}')
    u_port_value=$(echo ${udp_port} | tr "=" " " | awk '{print $2}')

    u_new_port_value=${u_port_value}

    while "true"; do
      detect_if_port_in_use "${u_new_port_value}" "UDP" ${u_port_name}
      if [ "${PORT_USAGE}" = "false" ]; then
        break
      fi
      read -p "${ERR} UDP port ${u_new_port_value} for ${u_port_name} is being used, please type another port: " u_new_port_value
    done
    if [ "${u_new_port_value}"x != "${u_port_value}"x ]; then
      env_substitute ${u_port_name} ${u_new_port_value}
    fi
  done
  logger ${INFO} "Checking if udp ports available...ok"
}

# --------------------------------------------------------------------- #
# Volumes checker
# --------------------------------------------------------------------- #
volumes_checker() {
  tcp_ports=$(cat ${INSTALL_PREFIX}/.env | grep "PORT" | grep "TCP")

  logger ${INFO} "Checking if tcp ports available..."
  for tcp_port in ${tcp_ports[@]}; do
    if [ "$(echo $tcp_port | grep '^MONITOR')"x != ""x ]; then
      continue
    fi
    t_port_name=$(echo ${tcp_port} | tr "=" " " | awk '{print $1}')
    t_port_value=$(echo ${tcp_port} | tr "=" " " | awk '{print $2}')

    t_new_port_value=${t_port_value}
    while "true"; do
      detect_if_port_in_use "${t_new_port_value}" "TCP" ${t_port_name}
      if [ "${PORT_USAGE}"x = "false"x ]; then
        break
      fi
      read -p "${ERR} TCP port ${t_new_port_value} for ${t_port_name} is being used, please type another port: " t_new_port_value
    done
    if [ "${t_new_port_value}"x != "${t_port_value}"x ]; then
      env_substitute ${t_port_name} ${t_new_port_value}
    fi
  done
  logger ${INFO} "Checking if tcp ports available...ok"
}



# --------------------------------------------------------------------- #
#  Set monitor server ip
# --------------------------------------------------------------------- #
set_monitor_server_ip() {
  while "true"; do
    read -p "${INFO} Please specify the ip address of the xcal-monitor-server: " monitor_server_ip
    if [ "${monitor_server_ip}"x != ""x ]; then
      loopback_test=$(ping -c 1 ${monitor_server_ip} | sed -n 1p | grep "127.0.0.1")
      if [ "${loopback_test}"x != ""x ]; then
        logger ${ERR} "xcal-monitor-server ip can not be loopback address, please specify an LAN ip."
      else
        logger ${INFO} "Validating xcal-monitor-server ip"
        ping -c 10 ${monitor_server_ip} >>${LOG_FILE} 2>&1
        if [ $? -eq 0 ]; then
          logger ${INFO} "xcal-monitor-server ip is reachable."
          env_substitute "MONITOR_SERVER_IP" ${monitor_server_ip}
          break
        else
          logger ${ERR} "xcal-monitor-server ip is unreachable.  Please retry."
        fi
      fi
    fi
  done
}

# --------------------------------------------------------------------- #
#  User define configuration
# --------------------------------------------------------------------- #
configure() {
  # get installation prefix
  while "true"; do
    if [ "${INSTALL_PREFIX}"x = ""x ]; then
      read -p "${INFO} Please enter the directory you wish to install the ${PRODUCT_NAME}, hit <Enter> to use default directory [${DEFAULT_INSTALL_PREFIX}]: " INSTALL_PREFIX
      if [ -z "${INSTALL_PREFIX}" ]; then
        INSTALL_PREFIX=${DEFAULT_INSTALL_PREFIX}
      fi

      read -p "${INFO} Please hit <Enter> again to confirm the directory you wish to install the ${PRODUCT_NAME} [${INSTALL_PREFIX}]: " INSTALL_PREFIX_RETRY
      if [ -z "${INSTALL_PREFIX_RETRY}" ]; then
        INSTALL_PREFIX_RETRY=${INSTALL_PREFIX}
      else
        INSTALL_PREFIX=${INSTALL_PREFIX_RETRY}
      fi
    fi
    if [ "$INSTALL_PREFIX"x != "$DEFAULT_INSTALL_PREFIX"x ]; then
      cp ${DEFAULT_INSTALL_PREFIX}/.env ${INSTALL_PREFIX}
      status_check $? "Copying .env to destination: $INSTALL_PREFIX."
    fi


    ### Check illeagal characters
    check_result=$(echo ${INSTALL_PREFIX} | grep '[^a-zA-Z0-9./_ -]')
    if [ "${check_result}"x != ""x ]; then
      logger ${ERR} "Install path contains invalid characters.  Only [a-zA-Z0-9./_ -] are allowed.  Installation aborted."
      exit 1
    fi

    ### Specified issue page url
    if [[ "$(cat ${INSTALL_PREFIX}/.env | grep "ISSUE_PAGE_URL")"x != ""x && "$(cat ${INSTALL_PREFIX}/.env | grep "ISSUE_PAGE_URL" | tr "=" " " | awk '{print $2}')"x != "http://127.0.0.1"x ]]; then
      logger ${INFO} "ISSUE_PAGE_URL specified to $(cat ${INSTALL_PREFIX}/.env | grep "ISSUE_PAGE_URL" | tr "=" " " | awk '{print $2}')"
    else
      issue_page_url=""
      while "true"; do
        read -rp "${INFO} Please input your ip address for external access(LAN ip, not loopback ip):" issue_page_url
        #confirm_issue_page_url=""
        #read -rp "${INFO} Ip address specified to ${issue_page_url}, confirm? [y/n]" confirm_issue_page_url
        if [ "${issue_page_url}"x = ""x ]; then
          logger ${ERR} "Empty ip address."
          issue_page_url=""
        elif [[ !(${issue_page_url} =~ $re) ]]; then
          logger ${ERR} "Format error ip address."
          issue_page_url=""
        else
          env_substitute "ISSUE_PAGE_URL" "http://${issue_page_url}"
          break
        fi
      done
    fi

    ### Monitor related config
    MONITOR_SERVER_OPTION=$(cat ${INSTALL_PREFIX}/.env | grep "MONITOR_SERVER_OPTION" | tr "=" " " | awk '{print $2}')
    if [ "${MONITOR_SERVER_OPTION}"x = ""x ]; then
      if_run_monitor_modules=""
      while [ "${if_run_monitor_modules}"x != "y"x -a "${if_run_monitor_modules}"x != "n"x ]; do
        read -p "${INFO} Do you wish to run cadvisor and node-exporter to collect the system usage information to monitor the server to capture?(y/n) [n]: " if_run_monitor_modules
        if [ "${if_run_monitor_modules}"x = ""x ]; then
          if_run_monitor_modules="n"
        fi
      done

      if [ "${if_run_monitor_modules}"x = "n"x ]; then
        env_substitute "MONITOR_SERVER_OPTION" "off" #&&
#          env_substitute "MONITOR_SERVER_IP" "127.0.0.1"
      else
        env_substitute "MONITOR_SERVER_OPTION" "on" &&
          env_substitute "CADVISOR_TCP_PORT" "8181" &&
          env_substitute "NODE_EXPORTER_TCP_PORT" "9100"
        monitor_server_ip=""
        set_monitor_server_ip
        env_substitute "MONITOR_SERVER_IP" ${monitor_server_ip}
      fi
    elif [ "${MONITOR_SERVER_OPTION}"x = "on"x ]; then
      logger ${INFO} "MONITOR_SERVER_OPTION is on."
      env_substitute "CADVISOR_TCP_PORT" "8181" &&
        env_substitute "NODE_EXPORTER_TCP_PORT" "9100"

      monitor_server_ip=$(cat ${INSTALL_PREFIX}/.env | grep "MONITOR_SERVER_IP" | tr "=" " " | awk '{print $2}')
      if [ "${monitor_server_ip}"x = ""x ]; then
        logger ${ERR} "Empty monitor server ip."
        set_monitor_server_ip
      elif [ "$(ping -c 1 ${monitor_server_ip} | sed -n 1p | grep "127.0.0.1")"x != ""x ]; then
        logger ${ERR} "xcal-monitor-server ip can not be loopback address, please specify an LAN ip."
        set_monitor_server_ip
      fi

    elif [ "${MONITOR_SERVER_OPTION}"x = "off"x ]; then
      logger ${INFO} "MONITOR_SERVER_OPTION is off."
#      env_substitute "MONITOR_SERVER_IP" "127.0.0.1"
    else
      logger ${ERR} "Unknown value ${MONITOR_SERVER_OPTION} for MONITOR_SERVER_OPTION."
      exit 1
    fi

    ### Database related config
    if [[ "$(cat ${INSTALL_PREFIX}/.env | grep "XCAL_DB_PASSWORD")"x != ""x && "$(cat ${INSTALL_PREFIX}/.env | grep "XCAL_DB_PASSWORD" | tr "=" " " | awk '{print $2}')"x != ""x ]]; then
      DB_PW=$(cat ${INSTALL_PREFIX}/.env | grep "XCAL_DB_PASSWORD" | tr "=" " " | awk '{print $2}')
    else
      while "true"; do
        read -sp "${INFO} Please specify password of the scan server database: " DB_PW
        echo ""
        if [ "${DB_PW}"x = ""x ]; then
          logger ${ERR} "Password cannot be empty."
          continue
        fi

        DB_PW_retry=""
        read -sp "${INFO} Please enter password again of the scan server database: " DB_PW_retry
        echo ""
        if [ "${DB_PW}"x = "${DB_PW_retry}"x ]; then
          env_substitute "XCAL_DB_PASSWORD" ${DB_PW}
          break
        else
          logger ${ERR} "Passwords don't match, please retry."
          DB_PW=""
        fi
      done
    fi

    ### Check ports
    ports_checker

    ### Check volumes 
    volumes_checker

    ### Check data volumes 
    if [ "${REUSE_DATA}"x != "n"x ]; then
      check_volume
    fi
    

    while [ -z "${IS_CONFIGURATION_CONFIRMED}" ]; do
      logger ${INFO} "Please confirm the configuration:"
      cat ${INSTALL_PREFIX}/.env
      read -p "${INFO} confirm? (y/n): " IS_CONFIGURATION_CONFIRMED
      if [ "${IS_CONFIGURATION_CONFIRMED}"x = "y"x ]; then
        logger ${INFO} "Configuration confirmed."
        break
      elif [ "${IS_CONFIGURATION_CONFIRMED}" = "n" ]; then
        logger ${INFO} "Installation canceled."
        exit 1
      else
        IS_CONFIGURATION_CONFIRMED=""
      fi
    done

    if [ -d "${INSTALL_PREFIX}/${PRODUCT_INSTALL_ROOT}" ]; then
      read -p "${WARN} Directory ${INSTALL_PREFIX}/${PRODUCT_INSTALL_ROOT} already exists, please hit <Enter> or enter <y> overwrite it? (y/n) [y]: " overwrite
      if [ -z "${overwrite}" -o "${overwrite}"x = "y"x ]; then
        break
      else
        INSTALL_PREFIX=
        exit 4
      fi
    else
      mkdir -p ${INSTALL_PREFIX}/${PRODUCT_INSTALL_ROOT} >>${LOG_FILE} 2>&1
      ret=$?
      if [ ${ret} -eq 0 ]; then
        break
      else
        logger ${ERR} "failed to create directory ${INSTALL_PREFIX}/${PRODUCT_INSTALL_ROOT}. Installation aborted."
        INSTALL_PREFIX=
        exit 5
      fi
    fi
  done

  PRODUCT_INSTALL_ROOT=${INSTALL_PREFIX}/${PRODUCT_INSTALL_ROOT}
  PRODUCT_COMPOSE_FILE=${PRODUCT_INSTALL_ROOT}/${PRODUCT_COMPOSE_FILE}
  SITE_COMPOSE_FILE=${PRODUCT_INSTALL_ROOT}/${SITE_COMPOSE_FILE}

  logger ${INFO} "Installing ${PRODUCT_NAME} into ${PRODUCT_INSTALL_ROOT} ..."
  logger ${INFO} "Extracting ${PRODUCT_TARBALL}..."
  bash -c "tar -xf ${PRODUCT_TARBALL} -C ${PRODUCT_INSTALL_ROOT} --strip-components=1"
  status_check $? "Extracting ${PRODUCT_TARBALL}"

  # set up folder and symlink for data
  data_path=""
  data_path_confirm="n"
  while [[ (-f "$data_path") || ("$data_path_confirm" != "Y") ]]; do  # folder not valid 
    [ -f "$data_path" ] && echo "$data_path is a file!"
    read -p "Please enter the absolute path for the data folder [default: $PRODUCT_INSTALL_ROOT/data]: " data_path
    
    #default value
    if [[ -z $data_path ]]; then
      data_path=$PRODUCT_INSTALL_ROOT/data
    fi
    
    read -p "Please confirm if you want use this as a data folder $data_path (Y/n): " data_path_confirm
  done


  if [[ ! -d "$data_path" ]] ; then  # not exist, create a folder
    mkdir $data_path
  fi

  if [[ "$data_path" != "$PRODUCT_INSTALL_ROOT/data" ]]; then  # if not equals to install root, make a symlink
    sudo mv $PRODUCT_INSTALL_ROOT/data $PRODUCT_INSTALL_ROOT/data_bkup
    sudo ln -sf $data_path $PRODUCT_INSTALL_ROOT/data
  fi

  volumes=(
    "INSTALL_PREFIX/data/volume/upload"
    "INSTALL_PREFIX/data/volume/scandata"
    "INSTALL_PREFIX/data/volume/tmp"
    "INSTALL_PREFIX/data/volume/diagnostic"
    "INSTALL_PREFIX/data/volume/logs"
    "INSTALL_PREFIX/data/volume/kafka"
    "INSTALL_PREFIX/data/volume/kafka-data"
    "INSTALL_PREFIX/data/volume/rules"
    "INSTALL_PREFIX/data/volume/customrules"
    "INSTALL_PREFIX/data/volume/pgdata"
  )

  for (( i=0; i<${#volumes[@]}; ++i )); do
          volumes[$i]="${volumes[$i]/INSTALL_PREFIX/$PRODUCT_INSTALL_ROOT}"
          echo "prepare folder ${volumes[$i]}"
          mkdir -p ${volumes[$i]}
  done

  cat ${PRODUCT_COMPOSE_FILE} | sed "s%INSTALL_PREFIX%${PRODUCT_INSTALL_ROOT}%g" >${SITE_COMPOSE_FILE}
}

# --------------------------------------------------------------------- #
# update elk config files
# --------------------------------------------------------------------- #
elkconfigure() {
  logger ${INFO} "elk configure start..."
  ELASTIC_TCP_PORT1=$(cat ${INSTALL_PREFIX}/.env | grep "ELASTIC_TCP_PORT1")
  e_port_value=$(echo ${ELASTIC_TCP_PORT1} | tr "=" " " | awk '{print $2}')
  LOGSTASH_TCP_PORT1=$(cat ${INSTALL_PREFIX}/.env | grep "LOGSTASH_TCP_PORT1")
  l_port_value=$(echo ${LOGSTASH_TCP_PORT1} | tr "=" " " | awk '{print $2}')
  LOGSTASH_TCP_PORT2=$(cat ${INSTALL_PREFIX}/.env | grep "LOGSTASH_TCP_PORT2")
  l_port2_value=$(echo ${LOGSTASH_TCP_PORT2} | tr "=" " " | awk '{print $2}')

  cp -rf .config .configbak
  sed -i "s/var_ELASTIC_TCP_PORT1/${e_port_value}/g" `grep var_ELASTIC_TCP_PORT1 -rl ./.config`
  sed -i "s/var_LOGSTASH_TCP_PORT1/${l_port_value}/g" `grep var_LOGSTASH_TCP_PORT1 -rl ./.config`
  sed -i "s/var_LOGSTASH_TCP_PORT2/${l_port2_value}/g" `grep var_LOGSTASH_TCP_PORT2 -rl ./.config`
  cp -rf .config/* ${PRODUCT_INSTALL_ROOT}/config

  logger ${INFO} "elk configure end."
}


# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
post_verification() {
  #file/directory check for all against compose file
  #image
  #share folder

  logger ${INFO} "Verifying ${PRODUCT_NAME} installed components..."
  if [ -f "${SITE_COMPOSE_FILE}" -a -d "${PRODUCT_INSTALL_ROOT}/data/volume" -a -f "${PRODUCT_INSTALL_ROOT}/images/${PRODUCT_IMAGES}" ]; then
    logger ${INFO} "Verifying ${PRODUCT_NAME} installed components...ok"
  else
    logger ${INFO} "Verifying ${PRODUCT_NAME} installed components...failed"
    logger ${ERR} "${PRODUCT_NAME} installer NOT successfully installed in directory ${PRODUCT_INSTALL_ROOT} with ${SITE_COMPOSE_FILE}"
    exit 6
  fi
  echo ""
}

# --------------------------------------------------------------------- #
#  Start cadvisor container
# --------------------------------------------------------------------- #
start_cadvisor() {
  cadvisor_port=$(cat ${INSTALL_PREFIX}/.env | grep CADVISOR_TCP_PORT | tr "=" " " | awk '{print $2}')
  logger ${INFO} "Running Cadvisor..."
  if [ "${OS_ID}"x = "macos"x -o "${OS_ID}"x = "ubuntu"x -o "${OS_ID}"x = "debian"x ]; then
    ${CMD_PREFIX} docker run \
      --volume=/:/rootfs:ro \
      --volume=/var/run:/var/run:rw \
      --volume=/sys:/sys:ro \
      --volume=/var/lib/docker/:/var/lib/docker:ro \
      --publish=${cadvisor_port}:8080 \
      --detach=true \
      --restart always \
      --name=xcal_cadvisor_${PRODUCT_VERSION} \
      xcal.cadvisor:${PRODUCT_VERSION} >>${LOG_FILE} 2>&1
    status_check $? "Running Cadvisor"
  elif [ "${OS_ID}"x = "centos"x -o "${OS_ID}"x = "rhel"x -o "${OS_ID}"x = "fedora"x -o "${OS_ID}"x = "amzn"x ]; then
    ${CMD_PREFIX} docker run \
      --privileged=true \
      --volume=/cgroup:/cgroup:ro \
      --volume=/:/rootfs:ro \
      --volume=/var/run:/var/run:rw \
      --volume=/sys:/sys:ro \
      --volume=/var/lib/docker/:/var/lib/docker:ro \
      --publish=${cadvisor_port}:8080 \
      --detach=true \
      --restart always \
      --name=xcal_cadvisor_${PRODUCT_VERSION} \
      xcal.cadvisor:${PRODUCT_VERSION} >>${LOG_FILE} 2>&1
    status_check $? "Running Cadvisor"
  fi
}

# --------------------------------------------------------------------- #
#  Start node-exporter container
# --------------------------------------------------------------------- #
start_node_exporter() {
  node_exporter_port=$(cat ${INSTALL_PREFIX}/.env | grep NODE_EXPORTER_TCP_PORT | tr "=" " " | awk '{print $2}')
  logger ${INFO} "Running Node-exporter..."
  ${CMD_PREFIX} docker run \
    --volume=/proc:/host/proc:ro \
    --volume=/sys:/host/sys:ro \
    --volume=/:/rootfs:ro \
    --publish=${node_exporter_port}:9100 \
    --detach=true \
    --restart always \
    --name=xcal_node-exporter_${PRODUCT_VERSION} \
    xcal.node-exporter:${PRODUCT_VERSION} \
    --path.procfs=/host/proc \
    --path.rootfs=/rootfs \
    --path.sysfs=/host/sys \
    --collector.filesystem.ignored-mount-points='^/(sys|proc|dev|host|etc)($$|/)' >>${LOG_FILE} 2>&1
  status_check $? "Running Node-exporter"
}

# --------------------------------------------------------------------- #
#  Start docker swarm
# --------------------------------------------------------------------- #
start_swarm() {
  # Prepare uninstall script first. Substitute INSTALL_PREFIX in uninstall script and xcalscan-service.sh
  logger ${INFO} "Configuring uninstall script..."
  cd ${INSTALL_PREFIX} &&
    mv ${PRODUCT_INSTALL_ROOT}/config/${PRODUCT}-${PRODUCT_VERSION}-uninstall.sh . &&
    chmod +x ${PRODUCT}-${PRODUCT_VERSION}-uninstall.sh
  status_check $? "Moving uninstall script"

  uninstall_script="$(ls ${PRODUCT}-${PRODUCT_VERSION}-uninstall.sh)"
  sed "s#XCAL_INSTALL_PREFIX#${INSTALL_PREFIX}#g" "${uninstall_script}" >temp_uninstall_script && mv temp_uninstall_script ${uninstall_script} && chmod +x ${uninstall_script} 
  status_check $? "Configuring uninstall script"

  # Start installdocker swarm
  logger ${INFO} "Initialising docker swarm..."
  swarm_mode_status=$(${CMD_PREFIX} docker info 2>&1 | grep "Swarm" | awk '{print $2}')

  if [ "${swarm_mode_status}" = "active" ]; then
    logger ${WARN} "Already In A Docker Swarm, Skip Init..."
  elif [ "${swarm_mode_status}" = "inactive" ]; then
    ${CMD_PREFIX} docker swarm init >>${LOG_FILE} 2>&1

    if [ $? != 0 ]; then
      logger ${ERR} "Initialising docker swarm...failed"
      logger ${ERR} "Please run \"${CMD_PREFIX} docker swarm init\" manually to fix this."
      exit 1
    else
      logger ${INFO} "Initialising docker swarm...ok"
    fi
  fi

  logger ${INFO} "Loading ${PRODUCT} service images from ${PRODUCT_INSTALL_ROOT}/images/${PRODUCT_IMAGES}..."
  ${CMD_PREFIX} docker load -i ${PRODUCT_INSTALL_ROOT}/images/${PRODUCT_IMAGES} >>${LOG_FILE} 2>&1
  status_check $? "Loading ${PRODUCT} service images from ${PRODUCT_INSTALL_ROOT}/images/${PRODUCT_IMAGES}"

  logger ${INFO} "Initialising attachable network xcal_wsnet_${NETWORK_SUFFIX}..."
  if [ "$(${CMD_PREFIX} docker network ls | grep -w xcal_wsnet_${NETWORK_SUFFIX})"x != ""x ]; then
    is_delete_network=""
    while "true"; do
      read -p "${INFO} xcal_wsnet_${NETWORK_SUFFIX} already exists, hit y to reuse it, hit n to recreate it.(y/n). " is_delete_network
      if [ "${is_delete_network}"x = "y"x ]; then
        logger ${INFO} "Reuse xcal_wsnet_${NETWORK_SUFFIX}."
        break
      elif [ "${is_delete_network}"x = "n"x ]; then
        logger ${INFO} "Recreating xcal_wsnet_${NETWORK_SUFFIX}..."
        ${CMD_PREFIX} docker network rm xcal_wsnet_${NETWORK_SUFFIX} >>${LOG_FILE} 2>&1 &&
          ${CMD_PREFIX} docker network create -d overlay --attachable xcal_wsnet_${NETWORK_SUFFIX} >>${LOG_FILE} 2>&1
        status_check $? "Recreating xcal_wsnet_${NETWORK_SUFFIX}"
        break
      fi
    done
  else
    ${CMD_PREFIX} docker network create -d overlay --attachable xcal_wsnet_${NETWORK_SUFFIX} >>${LOG_FILE} 2>&1
    status_check $? "Initialising attachable network xcal_wsnet_${NETWORK_SUFFIX}"
  fi

  logger ${INFO} "Starting ${PRODUCT} services, please wait..."
  converted_product_version=$(echo ${PRODUCT_VERSION} | tr "." "-")

  ${CMD_PREFIX} env $(cat ${INSTALL_PREFIX}/.env | grep "^[A-Z]" | xargs) docker stack deploy -c ${SITE_COMPOSE_FILE} ${PRODUCT}-${converted_product_version} >>${LOG_FILE} 2>&1 &&
    sleep 20

  status_check $? "Starting ${PRODUCT} services"
  echo ""

  if [ "${REUSE_DATA}"x != "n"x ]; then
    copy_volume
  fi

  MONITOR_SERVER_OPTION=$(cat ${INSTALL_PREFIX}/.env | grep "MONITOR_SERVER_OPTION" | tr "=" " " | awk '{print $2}')
  if [ "${MONITOR_SERVER_OPTION}"x = "on"x ]; then
    logger ${INFO} "Running monitor related containers."
    start_cadvisor && start_node_exporter
  fi

  ## Substitute INSTALL_PREFIX in uninstall script and xcalscan-service.sh
  logger ${INFO} "Configuring xcalscan-service script..."
  cd ${INSTALL_PREFIX} && 
    mv ${PRODUCT_INSTALL_ROOT}/config/xcalscan-service.sh . && 
    chmod +x xcalscan-service.sh
  status_check $? "Moving xcalscan-service script"

  sed "s#XCAL_INSTALL_PREFIX#${INSTALL_PREFIX}#g" xcalscan-service.sh >temp_xcalscan-service && mv temp_xcalscan-service xcalscan-service.sh && chmod +x xcalscan-service.sh
  status_check $? "Configuring xcalscan-service script"

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
  ${CMD_PREFIX}  docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --create --topic job-scan-engine-runner --zookeeper zookeeper:2181 --partitions 3 --replication-factor 1" > /dev/null 2>&1
  number_of_partitions=$(docker exec $new_kafka_id /bin/bash -c "/opt/kafka/bin/kafka-topics.sh --describe --zookeeper zookeeper:2181 --topic job-scan-engine-runner | awk '{print \$2}' | uniq -c | awk 'NR==2{print \$1}'")
  if [[ "$number_of_partitions" -ne 3 ]]; then
    ${CMD_PREFIX} docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper:2181 --alter --topic job-scan-engine-runner --partitions 3"
  else
    echo "topic partitions has set to 3 already"
  fi
}


# --------------------------------------------------------------------- #
#check existing volumes
# --------------------------------------------------------------------- #
check_volume() {
  logger ${INFO} "Finding previous docker volumes..."
  volumes_find_res=`${CMD_PREFIX} docker volume ls 2>&1 | grep ${VOLUME_NAME} | awk '{print $2}'`
  status_check $? "Finding previous docker volumes..."

  if [ "${volumes_find_res}"x != ""x ]; then
    for volume in ${volumes_find_res}
    do
      temp=${volume#*xcalscan-}
      #echo ${temp}
      tempversion=${temp%_*}
      #echo ${tempversion}
      vers=${tempversion//-/.}
      #echo ${vers}
      EXISTINGVERS=${EXISTINGVERS}"|"${vers}
    done 
	  #echo ${EXISTINGVERS}
	  array=(${EXISTINGVERS//|/ })   
	
    if [ "${REUSE_DATA}"x != ""x ]; then
      if_use=${REUSE_DATA}
      for var in ${array[@]}
      do
        #echo $var
        if [[ "${if_use}" = $var ]]; then
          if_match="y"
          break
        fi
      done
      if [ "${if_match}" != "y" ]; then
        if_use="no"
      fi
    fi
	  while [ "${if_use}"x = ""x ]; do
      read -p "${WARN} Please confirm if use previous volumes (${EXISTINGVERS}). Choose version: " if_use
      for var in ${array[@]}
      do
        #echo $var
		    if [[ "${if_use}" = $var ]]; then
		      if_match="y"
          break
        fi
      done
		  if [ "${if_match}" != "y" ]; then
		    if_use=""
		  fi
    done
	  #echo ${if_use}
	  #copy_volume
  else
    logger ${INFO} "No previous volumes found.  Skip."
  fi
}

# --------------------------------------------------------------------- #
#Copy existing volumes
# --------------------------------------------------------------------- #
copy_volume() {
  if [ "${if_use}" != "no" -a "${if_use}" != "" ]; then
		  selectedversion=${if_use//./-}
		  mountpoint=""
		  pathlen=0
		  #echo ${selectedversion}
			volumes_find_res1=`${CMD_PREFIX} docker volume ls 2>&1 | grep ${selectedversion}_ | awk '{print $2}'`
			for volume1 in ${volumes_find_res1}
			do
        #echo ${volume1}
				mountpoint=`${CMD_PREFIX} docker inspect ${volume1} 2>&1 | grep Mountpoint | awk '{print $2}'`
				mountpoint=${mountpoint: 1 : $[${#mountpoint} -3]}
				#echo ${mountpoint}
				newmountpoint="${mountpoint/${selectedversion}/${converted_product_version}}"
				newmountpoint="${newmountpoint///_data/}"
				#echo ${newmountpoint}			
        if [ "${selectedversion}" != "${converted_product_version}" ]; then
          sudo cp -rf 	${mountpoint}  ${newmountpoint}
				  status_check $? "Copying previous docker volume..."
          
        fi
      done      
      refresh_volume
	fi
}

# --------------------------------------------------------------------- #
#Refresh existing volumes
# --------------------------------------------------------------------- #
refresh_volume() {
  echo "${INFO} Refresh docker volume, please wait..."
  #echo "${INFO} xcal.database:${converted_product_version}"
  container_find_res=`${CMD_PREFIX} docker ps 2>&1 | grep xcal.database:${converted_product_version} | awk '{print $1}'`
  status_check $? "Finding db container..."
  for container1 in ${container_find_res}
  do
     ${CMD_PREFIX} docker stop ${container1}
     status_check $? "Refresh docker volume..."
	done
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
open_up_browser() {
  set_product_install_port="$(cat ${INSTALL_PREFIX}/.env | grep "APIGATEWAY_TCP_PORT" | tr "=" " " | awk '{print $2}')"
  set_issue_page_url="$(cat ${INSTALL_PREFIX}/.env | grep "ISSUE_PAGE_URL" | tr "=" " " | awk '{print $2}')"
  echo "${INFO} Please visit ${set_issue_page_url}:${set_product_install_port} and login with default Administrator user:
    Account:  admin
    Password: admin"
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
clear_cache() {
  sudo bash -c "echo 1 > /proc/sys/vm/drop_caches"  ##Clear buffer cache
}

# --------------------------------------------------------------------- #
#
# --------------------------------------------------------------------- #
end_banner() {
  logger ${INFO} "Installing ${PRODUCT_NAME}:${PRODUCT_VERSION} into your system...ok"
  exit 0
}

# --------------------------------------------------------------------- #
#  Main installation process
# --------------------------------------------------------------------- #
install() {
  start_banner
  dependency_check
  os_identification
  id_identification
  clear_cache
  memory_check
  disk_space_check
  pre_verification
  configure
  #elkconfigure
  start_swarm
  clear_cache
  post_verification
  open_up_browser
  end_banner
}

while "true"; do
  if [ $# -eq 0 ]; then
    break
  fi

  case "${1}" in
  --installprefix)
    shift
    echo "${INFO} INSTALL_PREFIX:${1}."
    INSTALL_PREFIX=${1}
    shift
    ;;
  --monitor)
    echo "${INFO} Turn on MONITOR_SERVER_OPTION."
    env_substitute "MONITOR_SERVER_OPTION" "on"
    shift
    echo "${INFO} MONITOR_SERVER_IP:${1}"
    env_substitute "MONITOR_SERVER_IP" "${1}" &&
      env_substitute "CADVISOR_TCP_PORT" "8181" &&
      env_substitute "NODE_EXPORTER_TCP_PORT" "9100"
    shift
    ;;
  --dbpwd)
    shift
    echo "${INFO} Database Password:${1}"
    env_substitute "XCAL_DB_PASSWORD" ${1}
    shift
    ;;
  --confirm)
    echo "${INFO} Configuration Confirmed."
    IS_CONFIGURATION_CONFIRMED="y"
    shift
    ;;
  --apiport)
    shift
    echo "${INFO} Apiport specified to:${1}"
    env_substitute "APIGATEWAY_TCP_PORT" ${1}
    shift
    ;;
  --mainport)
    shift
    echo "${INFO} JAVA_MAIN_TCP_PORT specified to:${1}"
    env_substitute "JAVA_MAIN_TCP_PORT" ${1}
    shift
    ;;
  --serverip)
    shift
    echo "${INFO} Server ip specified to:${1}"
    env_substitute "ISSUE_PAGE_URL" ${1}
    shift
    ;;
  --reusedata)
    shift
    echo "${INFO} REUSE_DATA specified to:${1}"
    REUSE_DATA=${1}
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

install

# set signal handler
trap cleanup 1 2 3 6
cleanup() {
  echo "Cleaning up ${PRODUCT} services"
  echo ""
}
