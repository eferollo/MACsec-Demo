#!/bin/bash

#set -x

# Console flag for opening a shell in each namespace
CONSOLE=0

# Define the directories where to save all the log files
LOG_DIR=`pwd`"/wan_logs"
LOG_DIR_HOSTS="${LOG_DIR}/hosts"
LOG_DIR_ROUTERS="${LOG_DIR}/routers"
LOG_DIR_WAN="${LOG_DIR}/wan"
# Define the path to the logrotate binaries
LOGROT_BIN="/usr/sbin/logrotate"

# Activate MACsec protection
MACSEC=0

###############################################################
# LOGGING FUNCTIONS
###############################################################

make_logs()
{
    mkdir -p ${LOG_DIR}

    # Create rtnetlink log rotation config if it doesn't exist
    [ ! -e "${LOG_DIR}/conf_rtnl" ] && cat << EOF > ${LOG_DIR}/conf_rtnl
${LOG_DIR}/rtnetlink.log {
    missingok
    rotate 10
}
EOF

    # Loop through namespaces and create log rotation config files if needed
    mkdir -p ${LOG_DIR_HOSTS}
    for n in $(seq 1 2); do
        ns_log_config="${LOG_DIR_HOSTS}/conf_ns${n}"

        [ ! -e "${ns_log_config}" ] && cat << EOF > ${ns_log_config}
${LOG_DIR_HOSTS}/ns${n}_veth${n}.pcap {
     missingok
     rotate 10
}
EOF
	  done
	
    mkdir -p ${LOG_DIR_ROUTERS}
    for n in $(seq 1 2); do
        ns_log_config="${LOG_DIR_ROUTERS}/conf_nsr${n}"

        [ ! -e "${ns_log_config}" ] && cat << EOF > ${ns_log_config}
${LOG_DIR_ROUTERS}/nsr${n}_macsec.pcap {
     missingok
     rotate 10
}
${LOG_DIR_ROUTERS}/nsr${n}_veth${n}_${n}.pcap {
     missingok
     rotate 10
}
${LOG_DIR_ROUTERS}/nsr${n}_vr${n}.pcap {
     missingok
     rotate 10
}
${LOG_DIR_ROUTERS}/nsr${n}_gretap.pcap {
     missingok
     rotate 10
}
${LOG_DIR_ROUTERS}/nsr${n}_br0.pcap {
     missingok
     rotate 10
}
EOF
	  done
	
    mkdir -p ${LOG_DIR_WAN}
    for n in $(seq 1 2); do
        ns_log_config="${LOG_DIR_WAN}/conf_wan${n}"

        [ ! -e "${ns_log_config}" ] && cat << EOF > ${ns_log_config}
${LOG_DIR_WAN}/wan${n}.pcap {
     missingok
     rotate 10
}
EOF
	  done
}

rotate_logs()
{
    # Rotate logs for each namespace
    for n in $(seq 1 2); do
        ${LOGROT_BIN} --force --state "${LOG_DIR_HOSTS}/state_ns${n}" "${LOG_DIR_HOSTS}/conf_ns${n}"
        ${LOGROT_BIN} --force --state "${LOG_DIR_ROUTERS}/state_nsr${n}" "${LOG_DIR_ROUTERS}/conf_nsr${n}"
        ${LOGROT_BIN} --force --state "${LOG_DIR_WAN}/state_wan${n}" "${LOG_DIR_WAN}/conf_wan${n}"
    done
	
    # Rotate the rtnetlink log
    ${LOGROT_BIN} --force --state "${LOG_DIR}/state_rtnl" "${LOG_DIR}/conf_rtnl"
}


###############################################################
# NETWORK SETUP FUNCTIONS
###############################################################

generate_random_mac()
{
    # Incrementing MAC prefix (start from a base OUI like 02:00:00)
    local ns_index=$1
    local prefix=$(printf "02:%02x:%02x" $(( (ns_index >> 8) & 0xFF )) $(( ns_index & 0xFF )))

    # Generate the remaining random 3 bytes (the suffix)
    local suffix=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | sed 's/\(..\)/:\1/g')

    # Combine the prefix and suffix to form the full MAC address
    echo "${prefix}${suffix}"
}

create_hosts() 
{
    # Start IP address for clients in the 10.0.1.0/16 network
    local base_ip="10.0.1."

    for n in $(seq 1 2); do
        local host="ns${n}"
        # Assign IP addresses incrementally
        local ip_address="${base_ip}$n/16"
        # Generate a random MAC address for each host
        local mac_address=$(generate_random_mac $n)
        
        # Create a new namespace for the host
        ${SUDO} ip netns add $host
        echo "Namespace $host created for site ${n}."

	if ip link show "veth${n}" &>/dev/null; then
            ${SUDO} ip link delete "veth${n}"
        fi
        
        # Create a veth pair to connect the host namespace to the default namespace
        ${SUDO} ip link add "veth${n}" type veth peer name "veth${n}_${n}"
        ${SUDO} ip link set "veth${n}" netns $host
        echo "veth pair created and moved to $host."

        # Assign the MAC address and IP address to the interface
        ip netns exec $host ip link set "veth${n}" address $mac_address
        ip netns exec $host ip address add $ip_address dev "veth${n}"
        ip netns exec $host ip link set "veth${n}" up
        echo "Configured $host with IP $ip_address and MAC $mac_address."

        sleep 0.1
        ${SUDO} ip netns exec $host su ${USER} -c "tcpdump -i veth${n} -U -w ${LOG_DIR_HOSTS}/ns${n}_veth${n}.pcap"&> /dev/null &

	if [ "${MACSEC}" -eq 0 ]; then
	    ${SUDO} ip netns exec "ns${n}" ip link set "veth${n}" mtu 1462
        else 
            ${SUDO} ip netns exec "ns${n}" ip link set "veth${n}" mtu 1430
        fi
	
        if [ "${CONSOLE}" -eq 1 ]; then
            # Launch the terminal
            konsole -T "terminal $host" -e \
            "${SUDO} ip netns exec $host bash -c \"echo 'Welcome to host $host of site ${n}'; exec bash\"" &
            TH[$n]=$!

            # Wait for terminal to launch
            sleep 0.5
        fi

      done
}

create_routers() 
{
    echo "Creating router namespaces nsr1 and nsr2..."

    for n in $(seq 1 2); do
        local router="nsr${n}"
        # Generate a random MAC address for each router
        local mac_address=$(generate_random_mac $n)

        # Create a new namespace for the router
        ${SUDO} ip netns add $router
        echo "Namespace $router created for site ${n}."

        ${SUDO} ip link set "veth${n}_${n}" netns "nsr${n}"
        ${SUDO} ip netns exec $router ip link set "veth${n}_${n}" up

        ${SUDO} ip link add "vr${n}" type veth peer name "wan${n}"
        ${SUDO} ip link set "vr${n}" netns "nsr${n}"

        # Configure router IP and default gateway
        ${SUDO} ip netns exec $router ip link set "vr${n}" address $mac_address
        ${SUDO} ip netns exec $router ifconfig "vr${n}" "${n}.${n}.${n}.${n}/24" up
        ${SUDO} ip netns exec $router ip route add default via "${n}.${n}.${n}.254"
        echo "Router nsr${n} configured with IP ${n}.${n}.${n}.${n}/24, default gateway ${n}.${n}.${n}.254."

        sleep 0.1
        ${SUDO} ip netns exec $router su ${USER} -c "tcpdump -i veth${n}_${n} -U -w ${LOG_DIR_ROUTERS}/veth${n}_${n}.pcap"&> /dev/null &
        ${SUDO} ip netns exec $router su ${USER} -c "tcpdump -i vr${n} -U -w ${LOG_DIR_ROUTERS}/vr${n}.pcap"&> /dev/null &

        if [ "${CONSOLE}" -eq 1 ]; then
            # Launch the terminal
            konsole -T "terminal $router" -e \
            "${SUDO} ip netns exec $router bash -c \"echo 'Welcome to router $router of site ${n}'; exec bash\"" &
            TR[$n]=$!

            # Wait for terminal to launch
            sleep 0.5
        fi
    done
}

create_wan() 
{
    echo "Creating WAN namespace and configuring interfaces..."

    # Create the WAN namespace
    ${SUDO} ip netns add wan
    echo "WAN namespace created."

    for n in $(seq 1 2); do
        # Generate a random MAC address for each wan interface
        local mac_address=$(generate_random_mac $n)

        # Configure the interfaces in WAN
        ${SUDO} ip link set "wan${n}" netns wan

        # Assign MAC addresses and IP addresses for WAN interfaces
        ${SUDO} ip netns exec wan ip link set "wan${n}" address $mac_address
        ${SUDO} ip netns exec wan ifconfig "wan${n}" "${n}.${n}.${n}.254" up

        echo "WAN interface configured: wan${n} (${n}.${n}.${n}.254)"

        sleep 0.1
        ${SUDO} ip netns exec "wan" su ${USER} -c "tcpdump -i wan${n} -U -w ${LOG_DIR_WAN}/wan${n}.pcap"&> /dev/null &
    done

    # Enable IP forwarding in the WAN namespace
    echo "Enabling IP Forwarding in the WAN namespace..."
    ${SUDO} ip netns exec wan sysctl -w net.ipv4.ip_forward=1
    echo "IP forwarding enabled in WAN."

    if [ "${CONSOLE}" -eq 1 ]; then
        # Launch the terminal
        konsole -T "terminal wan" -e \
        "${SUDO} ip netns exec wan bash -c \"echo 'Welcome to WAN'; exec bash\"" &
        TW[0]=$!

        # Wait for terminal to launch
        sleep 0.5
    fi
}

create_tunnel() 
{
    echo "Creating GRE tunnels between network namespaces..."
        for i in $(seq 1 2); do
            local router="nsr$i"
            local local_ip="$i.$i.$i.$i"
            local remote_ip="$((3 - i)).$((3 - i)).$((3 - i)).$((3 - i))"
            local mac_address="00:00:00:$i$i:$i$i:$i$i"

            echo "Setting up GRE tunnel in namespace $router:"
            echo "    Local IP: $local_ip"
            echo "    Remote IP: $remote_ip"
            echo "    MAC address: $mac_address"

            # Create the GRE tunnel
            ${SUDO} ip netns exec $router ip link add gretap1 type gretap local $local_ip remote $remote_ip
            ${SUDO} ip netns exec $router ip link set gretap1 address $mac_address
            ${SUDO} ip netns exec $router ip link set gretap1 up

            echo "Creating MACsec interface linked to gretap1..."
            # Create MACsec interface
            if [[ "$MACSEC" -eq 1 ]]; then
            	${SUDO} ip netns exec $router ip link add link gretap1 macsec0 type macsec encrypt on
	    fi
	    
            sleep 0.1
            ${SUDO} ip netns exec $router su ${USER} -c "tcpdump -i gretap1 -U -w ${LOG_DIR_ROUTERS}/gretap.pcap"&> /dev/null &
        done
    echo 'GRETAP tunnel between the sites created successfully...'
}


setup_macsec() 
{
    # Function to generate a random 32-character hex key
    generate_key() {
         dd if=/dev/urandom count=16 bs=1 2>/dev/null | hexdump | cut -c 9- | tr -d ' \n'
    }

    echo "Setting up MACsec with random generated keys..."

    # Generate two keys and assign them to match requirements
    local key1=$(generate_key)
    local key2=$(generate_key)

    # Ensure tx[0] = rx[1] and tx[1] = rx[0]
    macsec_tx_keys=("$key1" "$key2")
    macsec_rx_keys=("$key2" "$key1")
    remote_macs=("00:00:00:22:22:22" "00:00:00:11:11:11")

    for i in 1 2; do
        local ns="nsr$i"
        local tx_key="${macsec_tx_keys[$((i - 1))]}"
        local rx_key="${macsec_rx_keys[$((i - 1))]}"
        local remote_mac="${remote_macs[$((i - 1))]}"

    	echo "Configuring MACsec in namespace $ns"
        #${SUDO} ip netns exec $ns ip macsec offload macsec0 mac
        ${SUDO} ip netns exec $ns ip macsec add macsec0 tx sa 0 pn 1 on key 01 $tx_key
        ${SUDO} ip netns exec $ns ip macsec add macsec0 rx address $remote_mac port 1
        ${SUDO} ip netns exec $ns ip macsec add macsec0 rx address $remote_mac port 1 sa 0 pn 1 on key 02 $rx_key
        ${SUDO} ip netns exec $ns ip link set macsec0 up
        echo "MACsec interface macsec0 configured and set to up."

        sleep 0.1
        ${SUDO} ip netns exec nsr${n} su ${USER} -c "tcpdump -i macsec0 -U -w ${LOG_DIR_ROUTERS}/macsec.pcap"&> /dev/null &
    done
    echo 'MACsec created successfully with random generated paired keys...'
}

setup_bridge() 
{
    echo "Setting up Linux bridges in each namespace..."

    if [ ${MACSEC} -eq 1 ]; then
        iface="macsec0"
    else
        iface="gretap1"
    fi

    for n in $(seq 1 2); do
        echo "Configuring bridge in namespace nsr$n"
        ${SUDO} ip netns exec nsr${n} ip link add br0 type bridge
        ${SUDO} ip netns exec nsr${n} ip link set "veth${n}_${n}" master br0
        ${SUDO} ip netns exec nsr${n} ip link set ${iface} master br0    
        ${SUDO} ip netns exec nsr${n} ip link set br0 up

        sleep 0.1
        ${SUDO} ip netns exec nsr${n} su ${USER} -c "tcpdump -i br0 -U -w ${LOG_DIR_ROUTERS}/br0.pcap"&> /dev/null &
    done

    echo 'Linux bridges created successfully...'
}

###############################################################
# NETWORK TEARDOWN FUNCTIONS
###############################################################

teardown_hosts() 
{
    for n in $(seq 1 2); do
        local host="ns${n}"
        ${SUDO} ip netns exec $host ip link set dev veth${n} down
        ${SUDO} ip netns del $host
        
        # Terminate the terminal if running
        if [ "${CONSOLE}" -eq 1 ] && [ -n "${TH[${n}]}" ]; then
            echo "Terminating terminal for ns${n} (PID: ${TH[${n}]})"
            ${SUDO} kill -SIGTERM "${TH[${n}]}" 2>/dev/null
        fi
    done
}

teardown_routers() 
{
    for n in $(seq 1 2); do
        local router="nsr${n}"
        ${SUDO} ip netns exec $router ip link set dev vr${n} down
        ${SUDO} ip netns exec $router ip link set dev veth${n}_${n} down
        ${SUDO} ip netns del $router

	# Terminate the terminal if running
        if [ "${CONSOLE}" -eq 1 ] && [ -n "${TR[${n}]}" ]; then
            echo "Terminating terminal for nsr${n} (PID: ${TR[${n}]})"
            ${SUDO} kill -SIGTERM "${TR[${n}]}" 2>/dev/null
        fi
    done
}

teardown_wan() 
{
    for n in $(seq 1 2); do
        ${SUDO} ip netns exec wan ip link set dev wan${n} down
    done

    # Terminate the terminal if running
    if [ "${CONSOLE}" -eq 1 ] && [ -n "${TW[0]}" ]; then
        echo "Terminating terminal for wan (PID: ${TW[0]})"
        ${SUDO} kill -SIGTERM "${TW[0]}" 2>/dev/null
    fi

    ${SUDO} ip netns del wan
}

teardown_tunnel_macsec() 
{
    for i in $(seq 1 2); do
        local router="nsr$i"
        if [ "$MACSEC" -eq 1 ]; then
            ${SUDO} ip netns exec $router ip link set dev macsec0 down
        fi
        ${SUDO} ip netns exec $router ip link delete gretap1
    done
}

teardown_bridge() 
{
    for i in $(seq 1 2); do
        local router="nsr$i"
        ${SUDO} ip netns exec $router ip link set dev br0 down
    done
}

###############################################################
# MISC
###############################################################

list_ns() 
{
    # Print the table header
    echo
    printf "%-10s %-20s %-20s\n" "Host" "IP Address" "MAC Address"
    printf "%-10s %-20s %-20s\n" "----" "-----------" "-----------"
    
    # List the hosts (ns1, ns2)
    for n in $(seq 1 2); do
        ip_addr=$(${SUDO} ip netns exec ns${n} ip addr show dev "veth${n}" 2>/dev/null | grep -oP '(?<=inet\s)\S+')
        mac_addr=$(${SUDO} ip netns exec ns${n} ip link show dev "veth${n}" 2>/dev/null | awk '/ether/ {print $2}')
        printf "Host %-3s   %-20s %-20s\n" "$n" "$ip_addr" "$mac_addr"
    done

    echo
    printf "%-10s %-20s %-20s\n" "Router" "IP Address" "MAC Address"
    printf "%-10s %-20s %-20s\n" "------" "-----------" "-----------"

    # List the routers (nsr1, nsr2)
    for n in $(seq 1 2); do
        ip_addr=$(${SUDO} ip netns exec nsr${n} ip addr show dev "vr${n}" 2>/dev/null | grep -oP '(?<=inet\s)\S+')
        mac_addr=$(${SUDO} ip netns exec nsr${n} ip link show dev "vr${n}" 2>/dev/null | awk '/ether/ {print $2}')
        printf "Router %-3s %-20s %-20s\n" "$n" "$ip_addr" "$mac_addr"
    done

    echo
    printf "%-10s %-20s %-20s\n" "WAN" "IP Address" "MAC Address"
    printf "%-10s %-20s %-20s\n" "---" "-----------" "-----------"

    # List the WAN interfaces (wan1, wan2)
    for n in $(seq 1 2); do
        ip_addr=$(${SUDO} ip netns exec wan ip addr show dev "wan${n}" 2>/dev/null | grep -oP '(?<=inet\s)\S+')
        mac_addr=$(${SUDO} ip netns exec wan ip link show dev "wan${n}" 2>/dev/null | awk '/ether/ {print $2}')
        printf "WAN %-3s    %-20s %-20s\n" "$n" "$ip_addr" "$mac_addr"
    done
}

###############################################################
# MAIN
###############################################################

main() 
{
    local line=$(printf '%0.s-' {1..90})
    if ! [ ${UID} -eq 0 ]; then
        SUDO="sudo"
    fi

    read -p "Do you want to open a shell in each namespace? (y/n): " open_shell
    if [[ "$open_shell" == "y" ]]; then
        CONSOLE=1
    else
        echo "To access each namespace, run the following command for each namespace:"
        for ns in $(seq 1 2); do
            echo "  ${SUDO} ip netns exec ns${ns} ${USER}"
        done
    fi
    
    # Choose between plain and MACsec
    read -p "Do you want to set up MACsec for security (y/n): " use_macsec
    if [ "$use_macsec" == "y" ]; then
    	MACSEC=1
    fi
    
    # Setup logs and rotate them
    make_logs
    rotate_logs

    echo $line
    # Creating the hosts (ns1, ns2)
    create_hosts

    echo $line
    # Creating the router namespaces (nsr1, nsr2)
    create_routers

    echo $line
    # Creating the WAN namespace and configuring interfaces
    create_wan

    echo $line
    # Setting up the GRE tunnel between the routers
    create_tunnel

    echo $line
    if [ "$MACSEC" -eq 1 ]; then
        setup_macsec
    else
        echo "Skipping MACsec setup"
    fi

    echo $line
    # Setting up the Linux bridges in each router namespace (nsr1, nsr2)
    setup_bridge

    sleep 0.1
    echo $line
    # Show menu
    action_opts="list show exit"
    select action_opt in $action_opts; do
        case $action_opt in
            list)
                list_ns
                ;;
            show)
                for n in $(seq 1 2); do
                    echo "MACsec context nsr${n} for site ${n}:"
                    ${SUDO} ip netns exec "nsr${n}" ip macsec show
                done
                ;;
            *)
                echo "Shutting down"
                break
                ;;
        esac
    done

    # Tear down the GRE tunnel and MACsec configuration
    teardown_tunnel_macsec

    # Tear down the Linux bridges in the router namespaces
    teardown_bridge

    # Tear down the WAN namespace and its interfaces
    teardown_wan

    # Tear down the router namespaces (nsr1, nsr2) and their interfaces
    teardown_routers

    # Tear down the host namespaces (ns1, ns2) and their interfaces
    teardown_hosts

    # Stop the rtnetlink monitor
    ${SUDO} kill -HUP "${RTNLMON}" 2>/dev/null

    echo "Done"
}

main

