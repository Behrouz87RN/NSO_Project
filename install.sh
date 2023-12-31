#!/bin/bash

# Check if all required command-line arguments are provided
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Please provide the path to the openrc file, tag, and public key as command-line arguments . $0 <openrc> <tag>"
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
echo "$formatted_time Starting deployment of ' $tag ' using ' $openrc_file ' for credentials."
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

# Check if an external network is available in the OpenStack environment
external_net=$(openstack network list --external --format value -c ID )
if [ -z "$external_net" ]; then
    echo "$formatted_time No external network found. Exiting."
    exit 1
fi

SecurityGroupExist1=$(openstack security group show -f value -c name "$SecurityGroup" 2>/dev/null )
SecurityGroupExist2=$(openstack security group show "${tag}_SG" 2>/dev/null)
if [[ -n "$SecurityGroupExist1" || "$SecurityGroupExist2" ]]; then
    echo "$formatted_time: The 'default' or  '${tag}_SG' Security group already exists."
else
    SecurityGroup="${tag}_SG"
    # Create a security group
    openstack security group create "$SecurityGroup" --description "Security Group for $tag" >/dev/null 2>&1
    openstack security group rule create --protocol any --ingress --remote-ip 0.0.0.0/0  "$SecurityGroup" >/dev/null 2>&1
    echo "$formatted_time: Created a security group with the tag '$tag': $SecurityGroup"
fi
#openstack security group create GroupName --description Description

# Check if floating IP addresses are available, and if not, create two new ones
floating_ips=$(openstack floating ip list -f value -c "Floating IP Address" )
floating_num=$(openstack floating ip list -f value -c "Floating IP Address" | wc -l )
if [[ floating_num -ge 1 ]]; then
# Use the second available floating IP for the proxy server
    floating_ip_bastion=$(echo "$floating_ips" | awk 'NR==1')
    echo "$formatted_time floating_ip_bastion $floating_ip_bastion"
    
    if [[ floating_num -ge 2 ]]; then
    # Use the first available floating IP for the Bastion server
        floating_ip_proxy=$(echo "$floating_ips" | awk 'NR==2')
        echo "$formatted_time floating_ip_proxy $floating_ip_proxy"
    else
         # Create a new floating IP address for the proxy server
        floating_ip_proxy=$(openstack floating ip create  "$external_net" >/dev/null 2>&1)
        echo "$formatted_time Created new floating IP for Proxy server: $floating_ip_proxy"
    fi
else
   # Create new floating IP addresses
    echo "$formatted_time creating floating IPs"
    floating_ip_1=$(openstack floating ip create "$external_net" 1>/dev/null)
    floating_ip_2=$(openstack floating ip create "$external_net"  1>/dev/null )
    #echo "Created two new floating IPs: $floating_ip_1 , $floating_ip_2"
    echo  "$formatted_time Allocating floating IP 1, 2. Done"
fi

# Check if the network with the specified tag already exists, and create if not
network_exists=$(openstack network show -f value -c name "$NetworkName" 2>/dev/null )
if [ -n "$network_exists" ]; then
    echo "$formatted_time A network already exists: $NetworkName"
else
    # Create the network
    openstack network create "$NetworkName" --tag "$tag" >/dev/null 2>&1
    echo "$formatted_time Network created with the tag '$tag': $NetworkName"
fi

# Check if the key with the specified tag already exists, and create if not
key_exists=$(openstack keypair list --format value --column Name | grep "^$KeyName$" )
if [ -n "$key_exists" ]; then
    echo "$formatted_time The key with the name '$KeyName' already exists. Skipping key creation."
else
# Create the keypair
    openstack keypair create --public-key "$PublicKey" "$KeyName" >/dev/null 2>&1
    echo "$formatted_time Key created with the name '$KeyName'"
fi
# Check if the subnet with the specified tag already exists, and create if not
subnet_exists=$(openstack subnet show -f value -c name "$SubnetName" 2>/dev/null )
if [ -n "$subnet_exists" ]; then
    echo "$formatted_time The subnet with the name '$SubnetName' already exists. Skipping subnet creation."
else
    #Create the subnet
    openstack subnet create --network "$NetworkName" --dhcp --ip-version 4 \
        --subnet-range 10.0.0.0/24 --allocation-pool start=10.0.0.50,end=10.0.0.150 \
        --dns-nameserver 1.1.1.1 "$SubnetName" >/dev/null 2>&1
    echo "$formatted_time Subnet created with the name '$SubnetName'"
fi

# Checking if the router with the specified tag already exists, and create if not
router_exists=$(openstack router show -f value -c name "$RouterName" 2>/dev/null )
if [ -n "$router_exists" ]; then
    echo "$formatted_time The router with the name '$RouterName' already exists. Skipping router creation."
else
    # Create the router
    openstack router create "$RouterName" --tag "$tag" --external-gateway "$external_net" >/dev/null 2>&1
    echo "$formatted_time Router created with the tag '$tag': $RouterName"
fi

# Check if the subnet is already attached to the router
subnet_attached=$(openstack port list --router "$RouterName" --fixed-ip subnet="$SubnetName" -f value -c ID)

if [ -n "$subnet_attached" ]; then
    echo "$formatted_time The router with the name '$RouterName' already has a subnet attached."
else
    # Add the subnet to the router
    openstack router add subnet "$RouterName" "$SubnetName" >/dev/null 2>&1
    echo "$formatted_time Subnet '$SubnetName' added to router '$RouterName'"
fi



# Check if the Bastion server with the specified tag already exists, and create if not
server_exists=$(openstack server show -f value -c name "$ServerName" 2>/dev/null)
if [ -n "$server_exists" ]; then
    echo "$formatted_time The Bastion server with the tag '$tag' already exists: $ServerName"
else
    openstack server create --flavor "$flavor" --image "$image_id" --network "$NetworkName" \
        --security-group "$SecurityGroup" --key-name "$KeyName" "$ServerName" >/dev/null 2>&1
        server_exists1=$(openstack server show -f value -c name "$ServerName" 2>/dev/null)
        if [ -n "$server_exists1" ]; then
            echo "$formatted_time Server created with the name '$ServerName'"
        fi
fi

# Check if the Proxy server with the specified tag already exists, and create if not
proxy_server_exists=$(openstack -q server show -f value -c name "$ProxyServerName" 2>/dev/null)
if [ -n "$proxy_server_exists" ]; then
    echo "$formatted_time The proxy server with the tag '$tag' already exists: $ProxyServerName"
else
# Create the Proxy server instance with the same configuration as the Bastion server
    openstack server create --flavor "$flavor" --image "$image_id" --network "$NetworkName" \
        --security-group "$SecurityGroup" --key-name "$KeyName" "$ProxyServerName" >/dev/null 2>&1 
        proxy_server_exists1=$(openstack -q server show -f value -c name "$ProxyServerName" 2>/dev/null)
        if [ -n "$proxy_server_exists1" ]; then
            echo "$formatted_time Proxy server created with the name '$ProxyServerName'"
        fi       
fi

# Read the number of nodes from server.conf
server_conf="server.conf"
num_nodes=$(grep -i "num_nodes" "$server_conf" | awk -F "=" '{print $2}' | tr -d ' ')
echo "$formatted_time Will need $num_nodes nodes (read from server.conf), launching them."
# Check if the Node servers with the specified tag already exist, and create if not
for ((i = 1; i <= num_nodes; i++)); do
    Node_server_exists=$(openstack server -q show -f value -c name "${tag}_Node$i" 2>/dev/null )
    if [ -n "$Node_server_exists" ]; then
        echo "$formatted_time The Node$i server with the tag '$tag' already exists: ${tag}_Node$i"
    else
        # Create the Node$i server instance with the same configuration as the previous servers
        openstack server create --flavor "$flavor" --image "$image_id" --network "$NetworkName" \
            --security-group "$SecurityGroup" --key-name "$KeyName" "${tag}_Node$i" >/dev/null 2>&1
        Node_server_exists1=$(openstack server -q show -f value -c name "${tag}_Node$i" 2>/dev/null)
        if [ -n "$Node_server_exists1" ]; then
            echo "$formatted_time server created with the name '${tag}_Node$i'"
        fi   
    fi
done

# Generate hosts file
hosts_file="hosts"
echo "[haproxy]" > "$hosts_file"
echo "${tag}_proxy" >> "$hosts_file"
echo "" >> "$hosts_file"
echo "[webservers]" >> "$hosts_file"
for ((i=1; i <= $num_nodes; i++)); do
    echo "${tag}_Node$i" >> "$hosts_file"
done
echo "" >> "$hosts_file"
echo "[all:vars]" >> "$hosts_file"
echo "ansible_user=ubuntu" >> "$hosts_file"
echo "ansible_ssh_private_key_file=/.ssh/$KeyNameP" >> "$hosts_file"
# Print a message indicating the hosts file has been created
echo "$formatted_time host configuration file created: $hosts_file"


bastion_ip=$(openstack server show -f value -c addresses $ServerName | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
#echo "$formatted_time IP bastion = '$bastion_ip'"
proxy_ip=$(openstack server show -f value -c addresses $ProxyServerName | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
#echo "$formatted_time IP proxy = '$proxy_ip'"

# Loop through the number of nodes and set the IP addresses
for ((i = 1; i <= num_nodes; i++)); do
    node_name="Node${i}"
    Node_ip=$(openstack server show -f value -c addresses "${tag}_${node_name}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    #echo "$formatted_time IP $node_name = '$Node_ip'"
done
#echo "$formatted_time IP proxy = '$proxy_ip'  | IP bastion = '$bastion_ip | IP Node1 = '$Node_ip'"

floating_ips=$(openstack floating ip list -f value -c "Floating IP Address" )
floating_ip_bastion=$(echo "$floating_ips" | awk 'NR==1')
#echo "$formatted_time floating_ip_bastion $floating_ip_bastion"
floating_ip_proxy=$(echo "$floating_ips" | awk 'NR==2')
#echo "$formatted_time floating_ip_proxy $floating_ip_proxy"

# Assign the floating IPs to the servers
openstack server add floating ip $ServerName $floating_ip_bastion 
openstack server add floating ip $ProxyServerName $floating_ip_proxy
#echo "$formatted_time Assigned floating IP $floating_ip_bastion to server $ServerName"
#echo "$formatted_time Assigned floating IP $floating_ip_proxy to server $ProxyServerName"

# # Generate SSH configuration file
ssh_config_file="config"
# # Clear the existing content of the SSH config file (optional, uncomment if needed)
> "$ssh_config_file"
for ((i=1; i<= num_nodes; i++)); do
    Node_ip=$(openstack server show -f value -c addresses "${tag}_Node$i" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    echo "# SSH configuration for ${tag}_Node$i" >> "$ssh_config_file"
    echo "Host ${tag}_Node$i" >> "$ssh_config_file"
    echo "  HostName $Node_ip" >> "$ssh_config_file"
    echo "  User ubuntu" >> "$ssh_config_file"
    echo "  StrictHostKeyChecking no" >> "$ssh_config_file"
    echo "  IdentityFile ~/.ssh/$KeyNameP" >> "$ssh_config_file"
    echo "" >> "$ssh_config_file"
done
echo "# SSH configuration for ${tag}_proxy" >> "$ssh_config_file"
echo "Host ${tag}_proxy" >> "$ssh_config_file"
echo "  HostName $proxy_ip" >> "$ssh_config_file"
echo "  User ubuntu" >> "$ssh_config_file"
echo "  StrictHostKeyChecking no" >> "$ssh_config_file"
echo "  IdentityFile ~/.ssh/$KeyNameP" >> "$ssh_config_file"

echo "$formatted_time Base SSH configuration file created: $ssh_config_file"


# Install Ansible on the Bastion server and run a playbook
echo "$formatted_time Installig  Ansible process  on bastion..."
ssh -o StrictHostKeyChecking=no -i $KeyNameP ubuntu@$floating_ip_bastion 'sudo apt update >/dev/null 2>&1 && sudo apt install -y ansible >/dev/null 2>&1 '
# Check if Ansible is installed by running ansible --version
ansible_version=$(ssh -i $KeyNameP ubuntu@$floating_ip_bastion 'ansible --version 2>/dev/null | grep "ansible" | awk "{print \$2}"')
if [ -z "$ansible_version" ]; then
    echo "$formatted_time Ansible installation failed or not found in bastion..."
fi
#echo "$ansible_version"

# Copy the public key, SSH config file, and Ansible playbook to the Bastion server
echo "$formatted_time Copying files and keys to the Bastion server"
#echo  "$KeyNameP" 
#echo "$PublicKey"
files=("hosts" "nginx_udp.j2" "nginx.conf" "$PublicKey" "$KeyNameP"  "$ssh_config_file"  "site.yaml" "server.conf" "my_flask_app.service"   "application2.py" "haproxy.cfg.j2" "snmpd.conf" )
# Check if files exist on the remote server, and add files that need to be copied to the "files_to_copy" array
files_to_copy=()
for file in "${files[@]}"; do
    scp  -i $KeyNameP -o BatchMode=yes $file ubuntu@$floating_ip_bastion:~/.ssh  &>/dev/null
done
# Copy the files that don't exist on the remote server
NumOfFailedCopy=0
for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
        ((NumOfFailedCopy++))
        echo "$formatted_time Failed to copy  $file"
    fi
done
if [ $NumOfFailedCopy -eq 0 ]; then
    echo "$formatted_time All Files copied successfully."
else 
    echo "$formatted_time Error copy ,  one files did not copy successfully."
fi

echo "$formatted_time Running playbook..."
# Run the Ansible playbook on the Bastion server
ssh -i $KeyNameP ubuntu@$floating_ip_bastion "ansible-playbook -i ~/.ssh/hosts ~/.ssh/site.yaml " 


echo "$formatted_time Done, solution has been deployed."
echo "$formatted_time Validates operation..."
NumOfNodes=0
for ((i = 1; i <= num_nodes; i++)); do

    CheckNodes=$(curl http://$floating_ip_proxy 2>/dev/null )
    echo "$formatted_time $CheckNodes"
    if [[ "$CheckNodes" == *"${tag}-node$i"* ]]; then
        ((NumOfNodes++))
    fi
done
if [ $NumOfNodes -eq $num_nodes ]; then
    echo "$formatted_time ok"
fi


# # Function to run SNMP get command
# run_snmpget() {
#   local ip="$1"
#   local oid="$2"
#   snmpget -t 1 -r 1 -v2c -c public "$ip":161 "$oid"
# }
# echo "$formatted_time Running SNMP check..."
# # Assuming your Bastion server's IP is stored in the $floating_ip_bastion variable
# # Modify the SNMP OID and other parameters as needed for your SNMP check
# snmp_oid="1.3.6.1.2.1.1.1.0"
# for ((i = 1; i <= 3; i++)); do
#     snmp_output=$(run_snmpget "${floating_ip_proxy}" "$snmp_oid" )
#     snmpwalk -c public -v2c $floating_ip_proxy:161 1.3.6.1.2.1.1.1
#     echo "SNMP Result for Iteration $i:"
#     echo "$snmp_output"
#     echo
#     sleep 1
# done

echo "$formatted_time Running SNMP check..."

# Assuming your Bastion server's IP is stored in the $floating_ip_bastion variable
# Modify the SNMP OID and other parameters as needed for your SNMP check
snmp_oid="1.3.6.1.2.1.1.1"
for ((i = 1; i <= 3; i++)); do
    snmpwalk -c public -v2c "$floating_ip_proxy:161" "$snmp_oid"
    echo
    sleep 1
done

