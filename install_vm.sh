#!/bin/sh

HOSTNAME_VM="test5"

DISTRIB="buster"
LVM_VG="work"
REPO_URL="http://httpredir.debian.org/debian"

DISK_SIZE="5G"
MEM_MB="2048"
INT_BR="br.0"
V_CPU="2"
V_CHIPSET='pc-i440fx-2.8'

FS_TYPE="ext4"
ROOTFS_LABEL="${HOSTNAME_VM}-root"
INSTALL_DIR="/tmp/vm_install/${HOSTNAME_VM}"
LVM_NAME="/dev/${LVM_VG}/${ROOTFS_LABEL}"
MEM_KB="$((${MEM_MB}*1024))"
DEVICE_NAME="/tmp/virtual_disk"

die_script(){
   echo "$1"
   exit 1
}

configuring_vm(){

  # mount special fs
  chroot ${INSTALL_DIR} bash -c 'mount -t proc none /proc'
  
  if [ "$?" -ne "0" ]
  then
    echo 'ERROR: Can not mount proc.' 
    return 1
  fi

  chroot ${INSTALL_DIR} bash -c 'mount -t sysfs none /sys' 
  
  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc
    echo 'ERROR: Can not mount sysfs.' 
    return 1
  fi

  printf "LABEL=${ROOTFS_LABEL} / ${FS_TYPE} defaults 0 0\n" >> ${INSTALL_DIR}/etc/fstab
  printf "${HOSTNAME_VM}" > ${INSTALL_DIR}/etc/hostname
  
  # change root password
  chroot ${INSTALL_DIR} bash -c 'passwd -d root'

  # configuring tzdata
  chroot ${INSTALL_DIR} bash -c 'ln -fs /usr/share/zoneinfo/Europe/Moscow /etc/localtime'
  chroot ${INSTALL_DIR} bash -c 'dpkg-reconfigure -f noninteractive tzdata'
  
  printf 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";\n' > ${INSTALL_DIR}/etc/apt/apt.conf.d/20recommends

  # configuring locale
  chroot ${INSTALL_DIR} bash -c 'apt-get install -y locales ssh sudo less bash-completion'

  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
    echo 'ERROR: Can not install packages.'  
    return 1
  fi

  sed -i  's/^\s*#\s*\(ru_RU\.UTF-\?8.*\)/\1/i' ${INSTALL_DIR}/etc/locale.gen
  chroot ${INSTALL_DIR} bash -c 'locale-gen'
  printf 'LANG=C.UTF-8\n' >> ${INSTALL_DIR}/etc/default/locale

  # install kernel
  chroot ${INSTALL_DIR} bash -c 'apt-get update && apt-get install -y linux-image-amd64' 

  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
    echo 'ERROR: Can not install kernel.'
    return 1
  fi

  # install grub
  test -e "${INSTALL_DIR}${DEVICE_NAME}" &&\
	  die_script "ERROR: ${INSTALL_DIR}${DEVICE_NAME} - file exist." ||\
	  mknod ${INSTALL_DIR}${DEVICE_NAME} b 7 25 

  chroot ${INSTALL_DIR} bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y grub2' 
  
  if [ "$?" -ne "0" ]
    then
      umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
      echo 'ERROR: Can not install package grub2.'
      return 1
    fi
  sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet/quiet console=ttyS0/' ${INSTALL_DIR}/etc/default/grub
  printf 'GRUB_TERMINAL="serial console"\n' >> ${INSTALL_DIR}/etc/default/grub
  printf 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"\n' >> ${INSTALL_DIR}/etc/default/grub

  chroot ${INSTALL_DIR} bash -c 'update-grub'
  sed -i "s!${DEVICE_NAME}!LABEL=${ROOTFS_LABEL}!" "${INSTALL_DIR}/boot/grub/grub.cfg"
  chroot ${INSTALL_DIR} bash -c "grub-install --force ${DEVICE_NAME}"
  rm ${INSTALL_DIR}${DEVICE_NAME}

  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
    echo 'can not install grub' 
    return 1
  fi

  return 0
}

echo "Create LVM for ${ROOTFS_LABEL}"
test "${ROOTFS_LABEL}" || die_script 'ERROR: LVM volume name is empty.'
vgs "${LVM_VG}" >/dev/null 2>&1 || die_script 'ERROR: Can not find vg.'
lvs "${LVM_VG}" 2>&1|grep "^\s\{1,\}${ROOTFS_LABEL}\s" && die_script 'ERROR: LVM volume already exist.'
lvcreate "${LVM_VG}" --name "${ROOTFS_LABEL}" -L ${DISK_SIZE} || die_script 'ERROR: Can not create lvm.'

test -e "${DEVICE_NAME}" && die_script "ERROR: ${DEVICE_NAME} - file exist." || mknod ${DEVICE_NAME} b 7 25 

losetup ${DEVICE_NAME} ${LVM_NAME}

echo "Create ${FS_TYPE} on ${DEVICE_NAME}"
mkfs -t ${FS_TYPE} -L ${ROOTFS_LABEL} ${DEVICE_NAME}

[ -d "${INSTALL_DIR}" ] || mkdir -p "${INSTALL_DIR}"

echo "Install system on ${DEVICE_NAME}"
mount ${DEVICE_NAME} ${INSTALL_DIR} &&\
  debootstrap "${DISTRIB}" "${INSTALL_DIR}" "${REPO_URL}" &&\
  configuring_vm 
    
if [ "$?" -ne "0" ]
then
  umount ${INSTALL_DIR} && losetup -d "${DEVICE_NAME}" && rm "${DEVICE_NAME}" "${INSTALL_DIR}${DEVICE_NAME}"
  die_script 'ERROR: Can not configured vm.'
fi

umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys ${INSTALL_DIR} && losetup -d "${DEVICE_NAME}" && rm "${DEVICE_NAME}"

virsh define /dev/stdin <<__EOF__
<domain type='kvm'>
  <name>${HOSTNAME_VM}</name>
  <memory unit='KiB'>${MEM_KB}</memory>
  <vcpu placement='static'>${V_CPU}</vcpu>
  <os>
    <type arch='x86_64' machine='${V_CHIPSET}'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/> 
  </features>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/kvm</emulator>
    <disk type='block' device='disk'>
      <source dev='${LVM_NAME}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='${INT_BR}'/>
      <model type='virtio'/></interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'></memballoon>
  </devices>
</domain>
__EOF__
