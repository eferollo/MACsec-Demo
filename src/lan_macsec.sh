#!/bin/bash

#set -x

# Number of network namespaces
N_NS=""
# Console flag for opening a shell in each namespace
CONSOLE=0

# Define the directory where to save all the log files
LOG_DIR=`pwd`"/lan_logs"
# Define the path to the logrotate binaries
LOGROT_BIN="/usr/sbin/logrotate"

# Define the path to the wpa_supplicant binaries
WPA_BIN="/usr/sbin/wpa_supplicant"
# Define the path to the wpa_supplicant configuration file
WPA_CONF="wpa_supplicant.conf"
# Define the wpa_supplicant debug options
WPA_OPTS="-dd -K -t"

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
    for ns in $(seq 1 ${N_NS}); do
        ns_log_config="${LOG_DIR}/conf_ns${ns}"

        [ ! -e "${ns_log_config}" ] && cat << EOF > ${ns_log_config}
${LOG_DIR}/wpa_supplicant_ns${ns}.log {
     missingok
     rotate 10
}
${LOG_DIR}/eth0_ns${ns}.pcap {
    missingok
    rotate 10
}
EOF

    done
}

rotate_logs()
{
    # Rotate logs for each namespace
    for ns in $(seq 1 ${N_NS}); do
        ${LOGROT_BIN} --force --state "${LOG_DIR}/state_ns${ns}" "${LOG_DIR}/conf_ns${ns}"
    done

    # Rotate the rtnetlink log
    ${LOGROT_BIN} --force --state "${LOG_DIR}/state_rtnl" "${LOG_DIR}/conf_rtnl"
}

###############################################################
# NETWORK SETUP FUNCTIONS
###############################################################

make_netns() {
    for ns in $(seq 1 ${N_NS}); do
        ${SUDO} ip netns add "ns${ns}"

        if [ "${CONSOLE}" -eq 1 ]; then
            # Launch the terminal
            konsole -T "terminal ns${ns}" -e \
            "${SUDO} ip netns exec ns${ns} bash -c \"echo 'Welcome to namespace ${ns}'; exec bash\"" &
            T[${ns}]=$!

            # Wait for terminal to launch
            sleep 0.5
        fi
    done
}

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

setup_iface_netns()
{
    for ns in $(seq 1 ${N_NS}); do
        # Remove existing veth if it exists
        ${SUDO} ip link delete veth${ns} 2>/dev/null

        # Create connected network interface pairs and move one end to the namespace
        ${SUDO} ip link add veth${ns} type veth peer name eth0 netns ns${ns}

        # Verify if eth0 was created successfully
        if ! ${SUDO} ip netns exec ns${ns} ip link show eth0 > /dev/null 2>&1; then
           echo "Error: eth0 not found in namespace ns${ns}. Aborting."
           exit 1
        fi

        # Generate a random MAC address
        new_mac=$(generate_random_mac)
        ${SUDO} ip netns exec ns${ns} ip link set dev eth0 address ${new_mac}

        echo "Assigned MAC address ${new_mac} to namespace ns${ns}"
    done
}

setup_bridge_netns()
{
    # Create a bridge for the virtual network interface
    ${SUDO} ip link add name labnet type bridge

    # Bring the bridge interface up
    ${SUDO} ip link set labnet up

    # Add each virtual interface to the bridge
    for ns in $(seq 1 ${N_NS}); do
        ${SUDO} ip link set veth${ns} master labnet
        ${SUDO} ip link set veth${ns} up
    done

    # Allow forwarding of 802.1X PAE address frames
    ${SUDO} sh -c 'echo "8" > /sys/devices/virtual/net/labnet/bridge/group_fwd_mask'
}

ifaces_up()
{
    # Bring up the bridge
    ${SUDO} ip link set dev labnet up

    # Bring up virtual network interfaces in each namespace
    for ns in $(seq 1 ${N_NS}); do
        ${SUDO} ip netns exec ns${ns} ip link set dev lo up
        ${SUDO} ip link set dev veth${ns} up
        ${SUDO} ip netns exec ns${ns} ip link set dev eth0 up
        ${SUDO} ip netns exec ns${ns} su ${USER} -c "tcpdump -i eth0 -U -w ${LOG_DIR}/eth0_ns${ns}.pcap ether proto 0x888e or ether proto 0x88e5 "&> /dev/null &
    done

    # Wait for interfaces to stabilize
    sleep 1
}

spawn_wpa_supplicant()
{
    for ns in $(seq 1 ${N_NS}); do
        # Log the start time of wpa_supplicant
        {
            echo "##################################"
            date
            echo "##################################"
        } >> ${LOG_DIR}/wpa_supplicant_ns${ns}.log

        # Determine the wpa_supplicant executable
        WPA_EXEC_NS="${WPA_BIN}_${ns}"
        if [ -x "${WPA_EXEC_NS}" ]; then
            WPA_EXEC_CMD="${WPA_EXEC_NS}"
        else
            WPA_EXEC_CMD="${WPA_BIN}"
        fi

        # Launch wpa_supplicant with appropriate parameters
        ${SUDO} ip netns exec ns${ns} ${WPA_EXEC_CMD} -B -D macsec_linux \
            -c ${WPA_CONF} -i eth0 -P ${LOG_DIR}/ns${ns}.pid \
            ${WPA_OPTS} -f ${LOG_DIR}/wpa_supplicant_ns${ns}.log
    done

    # Allow time for MACsec devices to be created if needed
    sleep 2
    
    # Verify if macsec0 was created
    if ! ${SUDO} ip netns exec ns${ns} ip link show macsec0 > /dev/null 2>&1; then
        echo "Error: macsec0 not created in namespace ns${ns}. Check wpa_supplicant logs."
        exit 1
    fi
}

###############################################################
# NETWORK TEARDOWN FUNCTIONS
###############################################################

remove_wpa_supplicant() 
{
    for ns in $(seq 1 ${N_NS}); do
        # Remove WPA supplicant and MACsec interface
        pid_file="${LOG_DIR}/ns${ns}.pid"

        if [ -e "${pid_file}" ]; then
            # Read the PID from the file
            pid=$(< "${pid_file}")
            # Terminate the WPA supplicant process
            ${SUDO} kill "${pid}"
            echo "Killed wpa_supplicant for ns${ns}"
        fi
    done
}

ifaces_down() 
{
    # Bring down virtual network interfaces and the bridge
    for ns in $(seq 1 ${N_NS}); do
        ${SUDO} ip netns exec "ns${ns}" ip link set dev lo down
        ${SUDO} ip link set dev "veth${ns}" down
        ${SUDO} ip netns exec "ns${ns}" ip link set dev eth0 down
    done

    # Bring down the bridge
    ${SUDO} ip link set dev labnet down
}

unbridge_netns() 
{
    if ip link show labnet > /dev/null 2>&1; then
        # Remove virtual network interfaces from the bridge
        for ns in $(seq 1 ${N_NS}); do
            # Detach each veth from the bridge
            ${SUDO} ip link set "veth${ns}" nomaster 
        done
        
        # Delete the bridge
        ${SUDO} ip link delete labnet type bridge
    fi
}

teardown_netns()
{
    for ns in $(seq 1 ${N_NS}); do
        # Terminate the terminal if running
        if [ "${CONSOLE}" -eq 1 ] && [ -n "${T[${ns}]}" ]; then
            echo "Terminating terminal for ns${ns} (PID: ${T[${ns}]})"
            ${SUDO} kill -SIGTERM "${T[${ns}]}" 2>/dev/null
        fi

        # Delete the network namespace
        ${SUDO} ip netns delete "ns${ns}"
    done
}

###############################################################
# MISC
###############################################################

get_num_namespaces() 
{
    read -p "Enter the number of network namespaces: " N_NS
    while ! [[ "$N_NS" =~ ^[1-9][0-9]*$ ]]; do
        echo "Invalid input. Please enter a positive integer."
        read -p "Enter the number of network namespaces: " N_NS
    done
}

###############################################################
# MAIN
###############################################################

main()
{
    if ! [ ${UID} -eq 0 ]; then
        SUDO="sudo"
    fi

    # Prompt user for the number of namespaces
    get_num_namespaces

    # Ask the user if they want to open a shell in each namespace
    read -p "Do you want to open a shell in each namespace? (y/n): " open_shell
    if [[ "$open_shell" == "y" ]]; then
        CONSOLE=1
    else
        echo "To access each namespace, run the following command for each namespace:"
        for ns in $(seq 1 "${N_NS}"); do
            echo "  ${SUDO} ip netns exec ns${ns} ${USER}"
        done
    fi

    # Setup logs and rotate them
    make_logs
    rotate_logs

    # Start rtnetlink monitor
    ${SUDO} ip -ts monitor all label all-nsid >> ${LOG_DIR}/rtnetlink.log & RTNLMON=$!

    # Create the network namespaces
    make_netns

    # Setup interfaces of each namespace
    setup_iface_netns

    # Setup bridge network
    setup_bridge_netns

    # Bring up all the interfaces
    ifaces_up

    echo -n "Simulating MACsec environment, press enter to start MKA and MACsec..."
    read -r answer
    echo "Spawning wpa_supplicants"

    # Run wpa_supplicants
    spawn_wpa_supplicant

    # Find MAC addresses used in each namespace
    for ns in $(seq 1 "${N_NS}"); do
        NS_MAC[${ns}]=$(sudo ip netns exec "ns${ns}" cat /sys/devices/virtual/net/macsec0/address)
    done

    # Configure IPv4 addresses
    for ns in $(seq 1 "${N_NS}"); do
        NS_IPv4[${ns}]="10.0.0.${ns}/16"
        ${SUDO} ip netns exec "ns${ns}" ip address add "${NS_IPv4[${ns}]}" dev macsec0
    done

    echo "MACsec simulation up and running..."

    # Show menu
    action_opts="list show exit"
    select action_opt in $action_opts; do
        case $action_opt in
            list)
                for ns in $(seq 1 "${N_NS}"); do
                    echo "NS${ns}: ${NS_IPv4[${ns}]} (${NS_MAC[${ns}]})"
                done
                ;;
            show)
                for ns in $(seq 1 "${N_NS}"); do
                    echo "MACsec context ns${ns}:"
                    ${SUDO} ip netns exec "ns${ns}" ip macsec show
                done
                ;;
            *)
                echo "Shutting down"
                break
                ;;
        esac
    done

    # Kill any active wpa supplicants
    remove_wpa_supplicant

    # Bring down all the interfaces
    ifaces_down

    # Unbridge network namespaces
    unbridge_netns

    # Tearsown the namespaces
    teardown_netns

    # Stop the rtnetlink monitor
    ${SUDO} kill -HUP "${RTNLMON}" 2>/dev/null

    echo "Done"
}

main
