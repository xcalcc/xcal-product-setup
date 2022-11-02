
############################################################
# Step 1. Initialize and checking
############################################################
init_and_checking(){
  #variables
  old_version=2.1.3
  new_version=2.1.4
  old_installation_folder_path=~/xcalibyte-xcalscan-2.1.3-installer
  new_installation_folder_path=~/xcalibyte-xcalscan-2.1.4-installer

  old_version_hyphen="$(echo $old_version | tr "." "-")"

  if [ ! -d "$old_installation_folder_path" ]; then
    echo "$old_installation_folder_path not exist"
    exit 1;
  fi
  
  if [ ! -d "$new_installation_folder_path" ]; then
    echo "$new_installation_folder_path not exist"
    exit 1;
  fi
  
}

############################################################
# Step 2. Before installation
############################################################
pre_install(){

  #[docker-host]stop old services
  #eg. cd ~/xcalibyte-xcalscan-2.0.1-installer
  #eg. ./xcalscan-service.sh stop
  
  sudo docker ps
  cd $old_installation_folder_path
  ./xcalscan-service.sh stop
  sudo docker ps

  # old_db_volume_path=`sudo docker volume inspect --format '{{ .Mountpoint }}'  "xcalscan-"$old_version_hyphen"_pgdata"`
  # sudo cp -rfp $old_db_volume_path $old_installation_folder_path/xcalibyte/xcalscan/$old_version/data/volume/pgdata

}

############################################################
# Step 3. Installation
############################################################
install(){
  #[docker-host]install new server
  
  cd $new_installation_folder_path
  ./xcalscan-"$new_version"-install.sh
  
  retVal=$?
  if [ $retVal -ne 0 ]; then
      echo "Error while installing"
      exit 2
  fi
}

############################################################
# Step 4. After Installation 
############################################################
post_install(){

  # wait till database is ready
  while true;do
      sleep 20
      replica_string=`sudo docker service ls|grep "xcalscan-"$new_version"_database"|  awk '{print $4}'`
      echo "database status: $replica_string"
      if [ "$replica_string" = "1/1" ]; then
          break
      fi
  done
  
    
  if [ "$old_version" != "$new_version" ]; then
    #Init variable after all service ready
    new_db_id=`sudo docker ps -qf "name=^xcalscan-"$new_version"_database"`
    
    # add columns, insert detault data and update constraint
    # TODO: remove when not require after specific version
    #sudo docker exec $new_db_id sh -c 'echo "alter table \"user\" add column config_num_code_display INT NULL DEFAULT 10000;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id psql -U xcalibyte -a xcalibyte -c "insert into setting (setting_key, setting_value, modified_by) VALUES ('retention_num', '5', 'system') on conflict do nothing;"
    sudo docker exec $new_db_id sh -c 'echo "alter table \"project\" add column retention_num INT NULL;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table \"issue_group\" add column scan_task_id UUID NULL;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table \"issue\" add column scan_task_id UUID NULL;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "update issue_group set scan_task_id = occur_scan_task_id;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "update issue set scan_task_id = (select scan_task_id from issue_group where id = issue.issue_group_id);"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue_group drop constraint issue_group_pkey cascade;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue_group add constraint issue_group_pkey PRIMARY KEY (scan_task_id,id);"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue_group drop constraint issue_group_scan_task_id_fkey cascade;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue_group add constraint issue_group_scan_task_id_fkey FOREIGN KEY (scan_task_id) REFERENCES xcalibyte.scan_task(id) ON DELETE SET null;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "CREATE INDEX IF NOT EXISTS idx_issue_group_scan_task ON xcalibyte.issue_group USING btree (scan_task_id);"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue drop constraint issue_issue_group_id_fkey cascade;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id sh -c 'echo "alter table issue add constraint issue_issue_group_id_fkey FOREIGN KEY (scan_task_id,issue_group_id) REFERENCES xcalibyte.issue_group(scan_task_id,id) ON DELETE cascade;"|psql -d xcalibyte xcalibyte'
    sudo docker exec $new_db_id psql -U xcalibyte -a xcalibyte -c "CREATE TABLE IF NOT EXISTS xcalibyte.issue_validation  (
      id uuid NOT NULL DEFAULT uuid_generate_v4(),
      project_id uuid NULL,
      scan_task_id uuid NULL,
      rule_code text NULL,
      file_path text NULL,
      function_name text NULL,
      variable_name text NULL,
      line_number int NULL,
      type text NULL,
      action text NULL,
      scope text NULL,
      created_by text,
      created_on timestamp default CURRENT_TIMESTAMP,
      modified_by text,
      modified_on timestamp default CURRENT_TIMESTAMP,
      CONSTRAINT issue_management_pkey PRIMARY KEY (id),
      CONSTRAINT issue_management_project_id_fkey FOREIGN KEY (project_id) REFERENCES xcalibyte.project(id) ON DELETE CASCADE
    );
    "
  fi

  #create topic and set to 3 partition
  ret=1
  until [ $ret -eq 0 ]; do
    echo "Checking if Kafka is ready"
    new_kafka_id=`${CMD_PREFIX} docker ps -qf "name=^xcalscan-"$new_version"_kafka"`  
    if [ ! -z "$new_kafka_id" ]; then
      sudo docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --version"
      ret=$?
    fi
    sleep 15
  done
  sudo docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --create --topic job-scan-engine-runner --zookeeper zookeeper:2181 --partitions 3 --replication-factor 1" > /dev/null 2>&1
  number_of_partitions=$(sudo docker exec $new_kafka_id /bin/bash -c "/opt/kafka/bin/kafka-topics.sh --describe --zookeeper zookeeper:2181 --topic job-scan-engine-runner | awk '{print \$2}' | uniq -c | awk 'NR==2{print \$1}'")
  if [[ "$number_of_partitions" -ne 3 ]]; then
    sudo docker exec $new_kafka_id sh -c "/opt/kafka/bin/kafka-topics.sh --zookeeper zookeeper:2181 --alter --topic job-scan-engine-runner --partitions 3"
  else
    echo "topic partitions has set to 3 already"
  fi
}
#[docker-host]verify new server

#[docker-host]uninstall old server 

#clean up
#clean up export file

############################################################
# Step 5. Rollback
############################################################
rollback(){
    cd $new_installation_folder_path && ./xcalscan-service.sh stop
    cd $old_installation_folder_path && ./xcalscan-service.sh start
}

#major flow
myself=`basename "$0"`
if [ $# -eq 0 ];then
    echo "Please upgrade as following example:"
    echo "  ./$myself [upgrade|preinstall|install|postinstall|rollback]"
    echo "Description:"
    echo "    upgrade: "
    echo "        Execute all preinstall, install and postinstall in order"
    echo "    preinstall: "
    echo "        Only execute the phase before installation to prepare data and environment"
    echo "    install: "
    echo "        Only install the new version"
    echo "    postinstall: "
    echo "        Only execute the phase after installation to migrate data"
    echo "    rollback: "
    echo "        Stop the new server and start the old server"
    exit 0
fi

setup_option=$1
case $setup_option in
   upgrade)
      init_and_checking
      pre_install
      retVal=$?
      if [ $retVal -ne 0 ]; then
              echo "error occurred $retVal"
              exit $retVal
      fi
      install
      post_install
      ;;
   preinstall)
      init_and_checking
      pre_install
      retVal=$?
      if [ $retVal -ne 0 ]; then
              echo "error occurred $retVal"
              exit $retVal
      fi
      ;;
   install)
      init_and_checking
      install
      ;;
   postinstall)
      init_and_checking
      echo "WARNING. this action will load and overwrite data from $db_export_folder_path/dbexport.pgsql into you database in package version:$new_version"
      echo "Please enter 'Y' if you are upgrading to $new_version"
      read -p 'Please confirm you would like to execute postinstall phase [Y/n]: ' confirm_postinstall
      if [ "$confirm_postinstall" != "Y" ]; then
          echo 'User Cancelled.'
          exit 3
      fi
      post_install
      ;;
   rollback)
      init_and_checking
      rollback
      ;;
   *)
     echo "option $setup_option is not supported"
     ;;
esac
