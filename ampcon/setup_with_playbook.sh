#!/usr/bin/env bash

hostname=$1
ipaddr=$2
subnet=$3
gw=$4
domain=$5
ns1=$6
ns2=$7
ntpserver=$8
newuser=$9
pass2=${10}

# check valid ipv4, from Tim
function check_ip_valid()
{
    # return 0 if match ip address
    if [[ "$1" =~ ^((2(5[0-5]|[0-4][0-9]))|[0-1]?[0-9]{1,2})(\.((2(5[0-5]|[0-4][0-9]))|[0-1]?[0-9]{1,2})){3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# NIC might not be fixed like this
NIC=ens4
DEVICE_NAME=$(ifconfig -a | grep -Po 'en.*:|eth\d+:' | sed 's/://g')
IFCFG=/etc/sysconfig/network-scripts/ifcfg-$NIC

# modify DEVICE in ifcfg-ens160
sed -r 's#(DEVICE=").*?(")#\1'"${DEVICE_NAME}"'\2#g' "${IFCFG}" > tmpfile && mv -f tmpfile "${IFCFG}"

echo "================================================================================"
echo "AmpCon Server Configuration, press Ctrl-C to abort"
echo "================================================================================"
#echo "Press Ctrl-C to abort"
#trap "exit" INT
#trap exit\ 0 INT
trap ctrl_c INT
function ctrl_c() {
  echo "** Trapped CTRL-C"
  exit
}

if [ -f "check_generate_pwd_util" ]; then
    echo "check check_generate_pwd_util exists."
    mysql_pwd=$(python -c 'from check_generate_pwd_util import CheckGeneratePasswd; print(CheckGeneratePasswd().get_random_passwd())')
    rabbitmq_pwd=$(python -c 'from check_generate_pwd_util import CheckGeneratePasswd; print(CheckGeneratePasswd().get_random_passwd())')
fi



function init_mysql_pwd() {
    echo "init mysql database pwd..."
    mysql -uroot -proot -e "GRANT All PRIVILEGES ON *.* to 'automation'@'localhost' IDENTIFIED BY '${mysql_pwd}' WITH GRANT OPTION;FLUSH PRIVILEGES"
    mysql -uroot -proot -e "GRANT All PRIVILEGES ON *.* to 'automation'@'%' IDENTIFIED BY '${mysql_pwd}' WITH GRANT OPTION;FLUSH PRIVILEGES"
    sed -i "s/automation:.*@/automation:${mysql_pwd}@/g" /etc/automation/automation.ini
    sed -i "s/automation:.*@/automation:${mysql_pwd}@/g" /usr/share/automation/server/alembic.ini
    echo "init mysql database pwd success"
}


function init_rabbitmq_pwd() {
    echo "init rabbitmq pwd..."
    rabbitmqctl change_password admin ${rabbitmq_pwd}
    sed -i "s/rabbitmq_pwd: .*/rabbitmq_pwd: ${rabbitmq_pwd}/g" /etc/automation/automation.ini
    sed -i "s/rabbitmq_pwd = .*/rabbitmq_pwd = ${rabbitmq_pwd}/g" /etc/automation/automation.ini
    echo "init rabbitmq pwd success"
}

hostname "$hostname"
echo $hostname > /etc/hostname

if grep ^IPADDR= $IFCFG &>/dev/null
then
  sed -i "s+^IPADDR=.*+IPADDR=${ipaddr}+" $IFCFG
else
  echo IPADDR=${ipaddr} >> $IFCFG
fi

if grep ^PREFIX= $IFCFG &>/dev/null
then
  sed -i "s+^PREFIX=.*+PREFIX=${subnet}+" $IFCFG
else
  echo PREFIX=${subnet} >> $IFCFG
fi

if grep ^GATEWAY= $IFCFG &>/dev/null
then
  sed -i "s+^GATEWAY=.*+GATEWAY=${gw}+" $IFCFG
else
  echo GATEWAY=${gw} >> $IFCFG
fi

#echo "domain $domain" > /etc/resolv.conf
echo "search $domain" > /etc/resolv.conf
echo "nameserver ${ns1}" >> /etc/resolv.conf
if [ ! -d $ns2 ]
then
  echo "nameserver ${ns2}" >> /etc/resolv.conf
fi

if grep ^DOMAIN= $IFCFG &>/dev/null
then
  sed -i "s+^DOMAIN=.*+DOMAIN=\"${domain}\"+" $IFCFG
else
  echo DOMAIN=\"${domain}\" >> $IFCFG
fi

if grep ^DNS1= $IFCFG &>/dev/null
then
  sed -i "s+^DNS1=.*+DNS1=${ns1}+" $IFCFG
else
  echo DNS1=${ns1} >> $IFCFG
fi

if [ ! -d $ns2 ]
then
  if grep ^DNS2= $IFCFG &>/dev/null
  then
    sed -i "s+^DNS2=.*+DNS2=${ns2}+" $IFCFG
  else
    echo DNS2=${ns2} >> $IFCFG
  fi
fi

sed -i "s+^BOOTPROTO=.*+BOOTPROTO=static+" $IFCFG
#ip addr add $ipaddr/$subnet broadcast $gw dev $NIC &>/dev/null
# delete existing
ip addr add $ipaddr/$subnet dev $NIC &>/dev/null
systemctl restart network &>/dev/null

#useradd -p $(openssl passwd -1 ${pass2}) $newuser && echo "Added user \`$newuser\`"
useradd -p $(openssl passwd -1 ${pass2}) $newuser

# stop ampcon and deal with 'global_ip'
systemctl is-active automation &>/dev/null && systemctl stop automation &>/dev/null

default_amp_cfg="/etc/automation/automation.ini"
sed -i "s/^.*global_ip.*$/global_ip = $ipaddr/g" $default_amp_cfg


oldIFS=$IFS
IFS=$'\n'

# deal with server domain name
agent_cnf="/usr/share/automation/server/agent/auto-deploy.conf"
agent_cnf_dir="/usr/share/automation/server/config_gen/"
vpn_client_cnf="/usr/share/automation/server/vpn/client.conf"
onie_install_sh="/usr/share/automation/server/onie_install/start.sh"
srv_domain=`grep -o -P '(?<=server_vpn_host).*\b' $agent_cnf | sed 's/[ =]//g'`
sed -i "s/server_vpn_host *= *$srv_domain/server_vpn_host = $ipaddr/g" $agent_cnf
sed -i "s/server_vpn_host *= *$srv_domain/server_vpn_host = $ipaddr/g" `grep -P "server_vpn_host *= *$srv_domain" -rl $agent_cnf_dir`
sed -i "s/server_host=\"$srv_domain\"/server_host=\"$ipaddr\"/g" $onie_install_sh
sed -i "s/remote \+$srv_domain/remote $ipaddr/g" $vpn_client_cnf

# mariadb fails, HINT shows possible trace with tz, so deal with it
systemctl is-active mariadb &>/dev/null && systemctl stop mariadb &>/dev/null

if grep -q "^server $ntpserver" /etc/ntp.conf
then
  sed -i "s+^server ${ntpserver}.*+server $ntpserver iburst+" /etc/ntp.conf
else
  echo "server $ntpserver iburst" >> /etc/ntp.conf
fi

if [ ! -d $ntpserver2 ]
then
  if grep -q "^server $ntpserver2" /etc/ntp.conf
  then
    sed -i "s+^server ${ntpserver2}.*+server $ntpserver2 iburst+" /etc/ntp.conf
  else
    echo "server $ntpserver2 iburst" >> /etc/ntp.conf
  fi
fi

IFS=$oldIFS

# For a possible quick sync first before ntpd
systemctl stop ntpd &>/dev/null
ntpdate $ntpserver &>/dev/null

systemctl is-enabled ntpd &>/dev/null || systemctl enable ntpd &>/dev/null
systemctl restart ntpd &>/dev/null


## restart, not `try-reload-or-restart`, for we need it to RUN
systemctl enable mariadb &>/dev/null
systemctl reload-or-restart mariadb

## start rabbitmq-server
systemctl enable rabbitmq-server &>/dev/null
systemctl reload-or-restart rabbitmq-server

# change default pwd.
if [ -f "check_generate_pwd_util" ]; then
    init_mysql_pwd
    init_rabbitmq_pwd
fi

# start AmpCon
systemctl enable automation &>/dev/null
systemctl reload-or-restart automation

echo
echo "================================================================================"
echo "System setup is now complete."
#echo "Please contact support@pica8.com if you run into any issue."
echo "================================================================================"
echo

echo "Starting configuration of AmpCon Automation Service"
# 1591249457
# You can get exact time zone string before running the setup script.
#    $ timedatectl list-timezones | grep America | grep Angeles

firewall-cmd --zone=public --remove-port=9001/tcp --permanent &>/dev/null
firewall-cmd --zone=public --remove-port=15672/tcp --permanent &>/dev/null
firewall-cmd --reload &>/dev/null


