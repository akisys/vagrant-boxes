#!/bin/sh

function_setupPuppet () {
  local JAILNAME="$1"
  if [ -z "$JAILNAME" ]; then
    echo 'No jailname given'
    exit 1
  fi
  echo "Setting up puppet"
  local UUID=`iocage get host_hostuuid ${JAILNAME}`
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg install puppet4
  if [ "`grep -c '/usr/local/etc/puppet' /iocage/jails/${UUID}/fstab`" == "0" ]; then
    iocage exec puppetmaster mv /usr/local/etc/puppet /usr/local/etc/puppet.dist
    iocage exec puppetmaster mkdir /usr/local/etc/puppet
    echo "/vagrant/puppet /iocage/jails/${UUID}/root/usr/local/etc/puppet nullfs rw 0 0" > /iocage/jails/${UUID}/fstab
    echo "Restarting ${JAILNAME} jail to ensure correct mounts"
    iocage stop $JAILNAME
    iocage start $JAILNAME
  fi
  local CWD=`pwd`
  local TARGET="/iocage/jails/${UUID}/root/usr/local/etc/puppet"
  echo "$TARGET"
  if [ ! -d "$TARGET" ]; then
    mkdir -p "$TARGET"
  fi
  if [ ! -f "$TARGET/puppet.conf" ]; then
    cd  $TARGET
    mkdir -p environments/production
    mkdir -p manifests
    mkdir -p modules
    cd environments/production
    ln -s ../../manifests manifests
    ln -s ../../modules modules
    cd $CWD
    cp /vagrant/setup/puppetconf/puppet.conf $TARGET/puppet.conf
  fi
  if [ ! -f "$TARGET/hiera.yaml" ]; then
    mkdir -p $TARGET/hieradata
    cp /vagrant/setup/puppetconf/hiera.yaml $TARGET/hiera.yaml
  fi
  if [ ! -d "/iocage/jails/${UUID}/root/var/puppet/ssl" ]; then
    echo "Starting puppetmaster for initial key setup"
    iocage exec $JAILNAME service puppetmaster onestart
    echo "Shutting down puppetmaster"
    iocage exec $JAILNAME service puppetmaster onestop
  fi
}

function_setupPuppetdb () {
  local JAILNAME="$1"
  if [ -z "$JAILNAME" ]; then
    echo 'No jailname given'
    exit 1
  fi
  echo "Setup puppetdb"
  local UUID=`iocage get host_hostuuid ${JAILNAME}`
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg install postgresql95-server
  local BASEDIR="/iocage/jails/${UUID}/root"
  local PGSQL_HOME="${BASEDIR}/usr/local/pgsql/data"
  local PUPPETDB_HOME="${BASEDIR}/usr/local/etc/puppetdb"
  local PUPPET_HOME="${BASEDIR}/usr/local/etc/puppet"
  if [ ! -d "$PGSQL_HOME" ]; then
    iocage exec $JAILNAME service postgresql oneinitdb
  fi
  iocage exec $JAILNAME service postgresql onestart
  if [ `egrep -c "puppetdb" $PGSQL_HOME/pg_hba.conf` -eq 0 ]; then
    echo "Initializing postgresql puppetdb access and database"
    echo "host    puppetdb             puppetdb             $PUPPET_IP/32            trust" >> $PGSQL_HOME/pg_hba.conf
    iocage exec $JAILNAME sudo -u pgsql createuser -dsr puppetdb
    iocage exec $JAILNAME sudo -u pgsql createdb puppetdb
    iocage exec $JAILNAME sudo -u pgsql psql -c 'CREATE EXTENSION pg_trgm;' puppetdb
    iocage exec $JAILNAME service postgresql onerestart
  fi
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg install puppetdb4 puppetdb-terminus4
  if `egrep -q "command_args=.*-D.*" $BASEDIR/usr/local/etc/rc.d/puppetdb`; then
    echo "Patching /usr/local/etc/rc.d/puppetdb"
    perl -pe 's/-D[a-z\.\/=]+ //g' $BASEDIR/usr/local/etc/rc.d/puppetdb > /tmp/rc_d_puppetdb
    cp /tmp/rc_d_puppetdb $BASEDIR/usr/local/etc/rc.d/puppetdb
  fi
  if [ `egrep -c '^#.*subname.*$' $PUPPETDB_HOME/conf.d/database.ini` -eq 1 ]; then
    echo "Adjusting puppetdb/conf.d/database.ini"
    cp /vagrant/setup/puppetdbconf/database.ini $PUPPETDB_HOME/conf.d/database.ini
    iocage exec $JAILNAME puppetdb ssl-setup
  fi
  iocage exec $JAILNAME service puppetdb onestart
  if [ ! -f "$PUPPET_HOME/puppetdb.conf" ]; then
    cp /vagrant/setup/puppetconf/puppetdb.conf $PUPPET_HOME/puppetdb.conf
  fi
  if [ `egrep -c '^storeconfigs_backend = puppetdb$'` -eq 0 ]; then
    echo "storeconfigs = true" >> $PUPPET_HOME/puppet.conf
    echo "storeconfigs_backend = puppetdb" >> $PUPPET_HOME/puppet.conf
    echo "reports = store,puppetdb" >> $PUPPET_HOME/puppet.conf
  fi
}

function_setupPuppetJail () {
  local JAILNAME="$1"
  if [ -z "$JAILNAME" ]; then
    echo 'No jailname given'
    exit 1
  fi
  echo "Setup '$JAILNAME' jail"
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg bootstrap
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg install vim-lite sudo tmux screen
  local UUID=`iocage get host_hostuuid ${JAILNAME}`
  local BASEDIR="/iocage/jails/${UUID}/root"
  (grep -q "$PUPPET_IP $PUPPET_HOSTNAME" $BASEDIR/etc/hosts) || (\
    echo "$PUPPET_IP $PUPPET_HOSTNAME" >> $BASEDIR/etc/hosts \
    )
}

function_setupPuppetserver () {
  local JAILNAME="$1"
  if [ -z "$JAILNAME" ]; then
    echo 'No jailname given'
    exit 1
  fi
  echo "Setup puppetserver"
  iocage exec $JAILNAME env ASSUME_ALWAYS_YES=YES pkg install puppetserver
  local UUID=`iocage get host_hostuuid ${JAILNAME}`
  local BASEDIR="/iocage/jails/${UUID}/root"
  local PUPPETSERVER_HOME="${BASEDIR}/usr/local/etc/puppetserver"
  if [ ! -f "$PUPPETSERVER_HOME/conf.d/puppetserver.conf.dist" ]; then
    echo "Setting up puppetserver/conf.d/puppetserver.conf"
    cp $PUPPETSERVER_HOME/conf.d/puppetserver.conf $PUPPETSERVER_HOME/conf.d/puppetserver.conf.dist
    perl -pe 's/^(\s+(master-conf-dir|master-code-dir):).*$/\1 \/usr\/local\/etc\/puppet/' $PUPPETSERVER_HOME/conf.d/puppetserver.conf.dist > $PUPPETSERVER_HOME/conf.d/puppetserver.conf
  fi
  iocage exec $JAILNAME service puppetserver onestart
}

function_activatePuppetmasterServices () {
  iocage exec $JAILNAME service postgresql onestart
  iocage exec $JAILNAME service puppetdb onestart
  iocage exec $JAILNAME service puppetserver onestart
}

# setup jail system
echo "Activating iocage on 'zroot'"
iocage activate zroot
(iocage list -r | grep -q '10.2-RELEASE') || (iocage fetch release=10.2-RELEASE)

# setup jails

## the puppetmaster
PUPPET_IP="172.23.100.100"
PUPPET_JAILNAME="puppetmaster"
PUPPET_HOSTNAME="puppet"
echo "Initializing '$PUPPET_JAILNAME' jail"
(iocage list | grep -q "$PUPPET_JAILNAME") || (
  echo "Creating $PUPPET_JAILNAME jail";
  iocage create -b tag=$PUPPET_JAILNAME base=10.2-RELEASE ip4_addr="jailbr0|$PUPPET_IP";
  )

if `iocage list | grep -q "$PUPPET_JAILNAME"`; then
  echo "Starting '$PUPPET_JAILNAME' jail"
  iocage stop $PUPPET_JAILNAME
  iocage set allow_sysvipc=1 $PUPPET_JAILNAME;
  iocage set hostname="$PUPPET_HOSTNAME" $PUPPET_JAILNAME;
  iocage start $PUPPET_JAILNAME;
fi

RUN_STATE=`iocage list | grep $PUPPET_JAILNAME | awk '{print $4}'`

if [ "$RUN_STATE" == "up" ]; then
  function_setupPuppetJail $PUPPET_JAILNAME
  function_setupPuppet $PUPPET_JAILNAME
  function_setupPuppetdb $PUPPET_JAILNAME
  function_setupPuppetserver $PUPPET_JAILNAME
fi

