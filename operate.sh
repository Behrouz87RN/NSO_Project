#!/bin/bash

# Check if all required command-line arguments are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Please provide the path to the openrc file, tag, and public key as command-line arguments."
    exit 1
fi
# Read the command-line arguments
openrc_file="$1"
tag="$2"
PublicKey="$3"
NetworkName="${tag}_network"
# Naming conventions for resources based on the provided tag
KeyName="${tag}_key"
SubnetName="${tag}_subnet"
RouterName="${tag}_router"
ServerName="${tag}_bastion"
ProxyServerName="${tag}_proxy"
#SecurityGroup="default"
SecurityGroup="${tag}_SG"
image_name="Ubuntu 22.04 J"
flavor="1C-2GB"
formatted_time=$(date +"%Y-%m-%d %H:%M:%S")

# Removing the ".pub" extension and storing it in a new variable
KeyNameP="${PublicKey%.pub}"
# Check if the file exists in the root folder
if [ ! -e "./$KeyNameP" ]; then
    echo "$formatted_time The file $KeyNameP does not exist in the root folder."
    exit 1
fi

# Source the OpenStack environment variables from the provided OpenRC file
source "$openrc_file"
echo "$formatted_time Starting Operate of ' $tag ' using ' $openrc_file ' for credentials."
#echo  "Starting deployment of $tag using $openrc_file for credential"
echo "$formatted_time Detecting suitable image, looking for Ubuntu 22.04 J"
# Find the image ID for Ubuntu 22.04
image=$(openstack image list --format value | grep "$image_name")
# Check if image is empty
if [[ -z "$image" ]]; then
    echo "$formatted_time Image  Ubuntu 22.04 not found: $image_name"
else
    image_id=$(echo "$image" | awk '{print $1}')
    #echo "Image found: $image"
    echo "$formatted_time Image Ubuntu 22.04 with ID : $image_id exist. "
fi


floating_ips=$(openstack floating ip list -f value -c "Floating IP Address" )
floating_ip_bastion=$(echo "$floating_ips" | awk 'NR==1')
echo "$formatted_time floating_ip_bastion $floating_ip_bastion"
floating_ip_proxy=$(echo "$floating_ips" | awk 'NR==2')
echo "$formatted_time floating_ip_proxy $floating_ip_proxy"




playbook() {
    echo "$formatted_time Running playbook..."
    ssh -o StrictHostKeyChecking=no -i $KeyNameP ubuntu@$floating_ip_bastion 'sudo apt update >/dev/null 2>&1 && sudo apt install -y ansible >/dev/null 2>&1'
    # Run the Ansible playbook on the Bastion server
    ssh -o StrictHostKeyChecking=no -i $KeyNameP ubuntu@$floating_ip_bastion "ansible-playbook -i ~/.ssh/hosts ~/.ssh/site.yaml "
}


# Create the  server
createServer () {
    local Server=$1
    openstack server create --flavor "$flavor" --image "$image_id" --network "$NetworkName" \
    --security-group "$SecurityGroup" --key-name "$KeyName" "$Server" --wait >/dev/null 2>&1 
    server_exists1=$(openstack -q server show -f value -c name "$Server" 2>/dev/null)
    if [ -n "$server_exists1" ]; then
        new_ip=$(openstack server show -f value -c addresses $Server | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        echo "$formatted_time server created with the name '$server_exists1' with ip: '$new_ip' "
        
    fi       
}


is_node_available() {
    local node="$1"
    local available_nodes="$2"
    for available_node in "${available_nodes[@]}"; do
        if [ "$node" = "$available_node" ]; then
            return 0 # Node found, return success (0)
        fi
    done
    return 1 # Node not found, return failure (non-zero)
}


udpate_files() {
    all_nodes=("$@")
    #echo "NEW Avialable nodes are ${all_nodes[@]}"

    ssh_config_file="config"
    # # Clear the existing content of the SSH config file (optional, uncomment if needed)
    > "$ssh_config_file"
    for server in "${all_nodes[@]}"; do
        Node_ip=$(openstack server show -f value -c addresses "$server" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        echo "# SSH configuration for $server" >> "$ssh_config_file"
        echo "Host $server" >> "$ssh_config_file"
        echo "  HostName $Node_ip" >> "$ssh_config_file"
        echo "  User ubuntu" >> "$ssh_config_file"
        echo "  StrictHostKeyChecking no" >> "$ssh_config_file"
        echo "  IdentityFile ~/.ssh/$KeyNameP" >> "$ssh_config_file"
        echo "" >> "$ssh_config_file"
    done
    echo "# SSH configuration for ${tag}_proxy" >> "$ssh_config_file"
    echo "Host ${tag}_proxy" >> "$ssh_config_file"
    echo "  HostName $floating_ip_proxy" >> "$ssh_config_file"
    echo "  User ubuntu" >> "$ssh_config_file"
    echo "  StrictHostKeyChecking no" >> "$ssh_config_file"
    echo "  IdentityFile ~/.ssh/$KeyNameP" >> "$ssh_config_file"

    #echo "$formatted_time Base SSH configuration file created: $ssh_config_file"
    sleep 1
     
    # Generate hosts file
    hosts_file="hosts"
    echo "[haproxy]" > "$hosts_file"
    echo "$ProxyServerName" >> "$hosts_file"
    echo "" >> "$hosts_file"
    echo "[webservers]" >> "$hosts_file"
    for server in "${all_nodes[@]}"; do
        echo "$server" >> "$hosts_file"
    done
    echo "" >> "$hosts_file"
    echo "[all:vars]" >> "$hosts_file"
    echo "ansible_user=ubuntu" >> "$hosts_file"
    echo "ansible_ssh_private_key_file=/.ssh/$KeyNameP" >> "$hosts_file"
    # Print a message indicating the hosts file has been created
    echo "$formatted_time host configuration file created: $hosts_file"
    sleep 1
    scp  -o BatchMode=yes config ubuntu@$floating_ip_bastion:~/.ssh/config &>/dev/null
    scp  -o BatchMode=yes hosts ubuntu@$floating_ip_bastion:~/.ssh/hosts &>/dev/null 
    sleep 1
}

check_and_delete_server() {
    local Server="$1"

    ServerUnreachableExists=$(openstack -q server show -f value -c name "$Server" 2>/dev/null)
    if [ -n "$ServerUnreachableExists" ]; then
        #echo "${formatted_time} The server with the tag ${tag} already exists but not available: ${Server} so it will be deleted..."
        if openstack server delete "$Server"; then
            echo "${formatted_time} Deleted $Server"
        else
            echo "${formatted_time} Failed to delete $Server"
        fi
    fi
}

validate_operation() {
    local num_nodes="$1"
    echo "$formatted_time Done, solution has been deployed."
    echo "$formatted_time Validates operation..."
    NumOfNodes=0

    for ((i = 1; i <= num_nodes; i++)); do
        CheckNodes=$(curl http://$floating_ip_proxy 2>/dev/null)
        echo "$formatted_time Request$i : $CheckNodes"
        if [[ "$CheckNodes" == *"${tag}-node$i"* ]]; then
            ((NumOfNodes++))
        fi
    done

    if ((NumOfNodes >= num_nodes)); then
        echo "$formatted_time OK"
    fi

    # Function to run SNMP get command
    echo "$formatted_time Running SNMP check..."
    # Assuming your Bastion server's IP is stored in the $floating_ip_bastion variable
    # Modify the SNMP OID and other parameters as needed for your SNMP check
    snmp_oid="1.3.6.1.2.1.1.1"
    for ((i = 1; i <= num_nodes; i++)); do
        snmpwalk -c public -v2c "$floating_ip_proxy:161" "$snmp_oid"
        echo
        sleep 1
    done


}


while true; do

    hosts_lines=$(ssh -i "$KeyNameP" ubuntu@"$floating_ip_bastion" 'cat ~/.ssh/hosts')
    # Extract server names from hosts in bastion server using awk and store them in an array
    server_names=()
    while IFS= read -r line; do
        server_names+=("$line")
    done < <(echo "$hosts_lines" | awk '/^\[webservers\]/{f=1; next} /^\[/{f=0} f && NF {print $1}')
    # Print the server names stored in the array after each other
    #echo ${formatted_time} list of servers which should be available:
    # for server in "${server_names[@]}"; do
    #     echo "                                                                  $server"
    # done
    

    # Set the path to the server.conf file
    config_file="./server.conf"
    # Read the content of the server.conf file and extract the value of "num_nodes"
    serverConf_Num=$(grep -oP 'num_nodes = \K\d+' "$config_file")
    # Check if the value is not empty
    if [ -z "$serverConf_Num" ]; then
        echo "${formatted_time} Error: Unable to find the value of '$num_nodes' in server.conf."
        exit 1
    fi
    echo "${formatted_time} Reading 'server.conf' Number of nodes required: $serverConf_Num Nodes"

    available_nodes=()
    unreachable_nodes=()

     # monitoring : ping hosts
    for Server in "${server_names[@]}"; do
        node_ip=$(openstack server show -f value -c addresses "$Server" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        #echo "${formatted_time} checking availability of server:'$Server with ip :'$node_ip"

        ssh -i $KeyNameP ubuntu@$floating_ip_bastion "ping -q -c 1 "$node_ip" " >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            available_nodes+=("$Server")
        else
            unreachable_nodes+=("$Server")
        fi
    done

    #echo "Servers with ping:"
    for server in "${available_nodes[@]}"; do
        echo "${formatted_time} ## monitoring alert: server   $server is avaliable "
    done
    num_available_nodes="${#available_nodes[@]}"
    #echo "Servers without ping:"
    for server in "${unreachable_nodes[@]}"; do
        echo "${formatted_time} @ monitoring alert server:   $server is unavaliable "
    done 
    num_unavailable_nodes="${#unreachable_nodes[@]}"

    #if [ "$num_available_nodes" -eq "$serverConf_Num" && "$num_unavailable_nodes" -eq 0  ]; then
    if [ "$num_available_nodes" -eq "$serverConf_Num" ] && [ "$num_unavailable_nodes" -eq 0 ]; then
        echo "${formatted_time} Checking solution, we have: $num_available_nodes nodes. Sleeping for 30 seconds.."
        sleep 30
        continue
    fi
 
    for Server in "${unreachable_nodes[@]}"; do
        echo "${formatted_time} Clean up unavailable Node : $Server"
        check_and_delete_server "$Server"
    done

    if [ "$num_available_nodes" -gt "$serverConf_Num" ]; then

        while [[ ${#available_nodes[@]} -ne $serverConf_Num ]]; do
            # remove extra servers name
            last_node="${available_nodes[num_available_nodes - 1]}"
            check_and_delete_server "$last_node"
            unset "available_nodes[$num_available_nodes - 1]"
            #echo ">>> ${available_nodes[@]}"
            num_available_nodes="${#available_nodes[@]}"
            sleep 2
        done

    elif [ "$num_available_nodes" -lt "$serverConf_Num" ]; then
    # Add new nodes
        #echo "Available Nodes ${available_nodes[@]}"
        # for ((i=1; i<=$serverConf_Num; i++)); do
        i=0
        while [[ ${#available_nodes[@]} -ne $serverConf_Num ]]; do
            ((i++))
            newNode="${tag}_Node$i"
              if [[ ! " ${available_nodes[*]} " =~ " $newNode " ]]; then
                echo "${formatted_time} Launching new node/s: ${newNode} waiting for completion"
                createServer "$newNode";
                sleep 2
                available_nodes+=("$newNode")
            fi
        done
    fi

    #echo "NEW Avialable nodes are ${available_nodes[@]}"
    num_available_nodes="${#available_nodes[@]}"
    udpate_files "${available_nodes[@]}"
    sleep 2
    num_available_nodes="${#available_nodes[@]}"
    playbook 
    validate_operation "$num_available_nodes"
done



# // check host file count
# // checking reachable or not
# // remove unrechables
# // check count of server config 
# // if eq  reachable    wait 30 loop
# // if  conf-NUM GT  reachable:  create server with available name ()
# // if  conf-NUM LT  reachable:  remove from the end servers
# // make ne w hosts file




