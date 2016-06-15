#!/bin/bash

set -e

mkdir -p /etc/kolla
mkdir -p /host/etc/kolla

ROLE=${1:-"compute"}
TIMEZONE=${HOST_TIMEZONE:-"America/Phoenix"}

write_kolla_globals() {
cat>/host/etc/kolla/globals.yml<<EOF
kolla_base_distro: "centos"
kolla_install_type: "binary"
openstack_release: "2.0.1"
kolla_internal_vip_address: "${OPENSTACK_INTERNAL_VIP_ADDRESS}"
docker_namespace: "kollarancher"
network_interface: "${OPENSTACK_API_INTERFACE}"
neutron_external_interface: "${OPENSTACK_NEUTRON_INTERFACE}"
neutron_plugin_agent: "openvswitch"
enable_haproxy: "False"
enable_heat: "yes"
enable_horizon: "yes"
EOF
}

if [ ! -e /host/etc/localtime ]; then
    cp /usr/share/zoneinfo/${TIMEZONE} /host/etc/localtime
fi

get_lock()
{
    set +e
    if ! $(mkdir /tmp/kolla.lock 2>/dev/null); then
        echo "Can not get lock... exiting"
        exit 1
    fi
    set -e
}

remove_lock()
{
    rm -rf /tmp/kolla.lock
}

configure_globals()
{
    if [ ! -e /host/etc/kolla/globals.yml ]; then
        echo "Writing new globals.yml"
        write_kolla_globals
        if [ -e /host/etc/kolla/password.yml ]; then
            rm /host/etc/kolla/password.yml
        fi
    fi
}

mount --bind /host/etc/kolla /etc/kolla
mount --bind /host/run /run

if [ ! -e /usr/bin/python ]; then
    echo "Symlinking python"
    ln -s /usr/local/bin/python /usr/bin/python
fi

configure_passwords()
{
    if [ ! -e /host/etc/kolla/passwords.yml ]; then
        echo "Generating new passwords"
        cp /usr/local/share/kolla/etc_examples/kolla/passwords.yml /host/etc/kolla/
        kolla-genpwd
        if [ -n "${OPENSTACK_ADMIN_PASSWORD}" ]; then
            sed -i "s/\(keystone_admin_password:\) \([a-zA-Z0-9].*\)/\1 ${OPENSTACK_ADMIN_PASSWORD}/" /host/etc/kolla/passwords.yml
        fi
    fi
}


setup_hostfile()
{
    echo "${OPENSTACK_INTERNAL_VIP_ADDRESS} $HOSTNAME $(hostname -s)">>/etc/hosts
}

run_kolla()
{
    while true; do
        if [ -e "/usr/local/share/kolla/ansible/inventory/rancher-inventory" ]; then
            break
        fi
    done
    
    ## Disable host checking because yeah... 
    ## Disable SSH ARGS because some OSes do not support the ControlPersist/ControlMaster args.
    export ANSIBLE_SSH_ARGS=
    export ANSIBLE_HOST_KEY_CHECKING=False
    kolla-ansible deploy -i /usr/local/share/kolla/ansible/inventory/rancher-inventory

    kolla-ansible post-deploy -i /usr/local/share/kolla/ansible/inventory/rancher-inventory
    . /etc/kolla/admin-openrc.sh
    /usr/local/share/kolla/init-runonce
    remove_lock
}

setup_ssh_private_key()
{
    if [ -n "${ANSIBLE_PRIVATE_SSH_KEY}" ]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        echo "${ANSIBLE_PRIVATE_SSH_KEY}" >/root/.ssh/id_rsa
        chmod 600 /root/.ssh/id_rsa
    fi
}

setup_ssh_authorized_keys()
{
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${ANSIBLE_PUBLIC_SSH_KEY}" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
}

run_sshd()
{
    mkdir -p /var/run/sshd
    sed -i 's/PermitRootLogin\ without-password/PermitRootLogin\ yes/' /etc/ssh/sshd_config
    exec /usr/sbin/sshd -D -p 64000
}

if [ "${ROLE}" = "controller" ]; then
    while true; do
        if [ -e "/usr/local/share/kolla/ansible/kolla-refresh" ]; then
            rm -f /usr/local/share/kolla/ansible/kolla-refresh
            get_lock
            trap remove_lock EXIT TERM 
            configure_globals
            configure_passwords
            setup_hostfile
            setup_ssh_private_key
            run_kolla
        fi

        sleep 30

    done
else
    setup_ssh_authorized_keys
    run_sshd
fi
