#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: ${DISK_IO:='native'}    # I/O Mode, can be set to 'native', 'threads' or 'io_turing'
: ${DISK_FMT:='raw'}      # Disk file format, "raw" by default for backwards compatibility
: ${DISK_CACHE:='none'}   # Caching mode, can be set to 'writeback' for better performance
: ${DISK_DISCARD:='on'}   # Controls whether unmap (TRIM) commands are passed to the host.
: ${DISK_ROTATION:='1'}   # Rotation rate, set to 1 for SSD storage and increase for HDD

DISK_OPTS=""
BOOT="$STORAGE/boot.img"

if [ -f "$BOOT" ]; then
  DISK_OPTS="$DISK_OPTS \
    -device virtio-scsi-pci,id=scsi0 \
    -drive id=cdrom0,if=none,format=raw,readonly=on,file=$BOOT \
    -device scsi-cd,bus=scsi0.0,drive=cdrom0,bootindex=10"
fi

fmt2ext() {
  local DISK_FMT=$1

  case "${DISK_FMT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    raw)
      echo "img"
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

ext2fmt() {
  local DISK_EXT=$1

  case "${DISK_EXT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    img)
      echo "raw"
      ;;
    *)
      error "Unrecognized file extension: .$DISK_EXT" && exit 78
      ;;
  esac
}

getSize() {
  local DISK_FILE=$1
  local DISK_EXT DISK_FMT

  DISK_EXT="$(echo "${DISK_FILE//*./}" | sed 's/^.*\.//')"
  DISK_FMT="$(ext2fmt "$DISK_EXT")"

  case "${DISK_FMT,,}" in
    raw)
      stat -c%s "$DISK_FILE"
      ;;
    qcow2)
      qemu-img info "$DISK_FILE" -f "$DISK_FMT" | grep '^virtual size: ' | sed 's/.*(\(.*\) bytes)/\1/'
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

resizeDisk() {
  local DISK_FILE=$1
  local CUR_SIZE=$2
  local DATA_SIZE=$3
  local DISK_SPACE=$4
  local DISK_DESC=$5
  local DISK_FMT=$6
  local GB REQ FAIL SPACE SPACE_GB

  GB=$(( (CUR_SIZE + 1073741823)/1073741824 ))
  info "Resizing $DISK_DESC from ${GB}G to $DISK_SPACE .."
  FAIL="Could not resize $DISK_FMT file of $DISK_DESC ($DISK_FILE) from ${GB}G to $DISK_SPACE .."

  REQ=$((DATA_SIZE-CUR_SIZE))
  (( REQ < 1 )) && error "Shrinking disks is not supported!" && exit 71

  case "${DISK_FMT,,}" in
    raw)
      if [[ "$ALLOCATE" == [Nn]* ]]; then

        # Resize file by changing its length
        if ! truncate -s "$DISK_SPACE" "$DISK_FILE"; then
          error "$FAIL" && exit 75
        fi

      else

        # Check free diskspace
        SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)
        SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))

        if (( REQ > SPACE )); then
          error "Not enough free space to resize $DISK_DESC to $DISK_SPACE in $DIR, it has only $SPACE_GB GB available.."
          error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting DISK_FMT to \"qcow2\"." && exit 74
        fi

        # Resize file by allocating more space
        if ! fallocate -l "$DISK_SPACE" "$DISK_FILE"; then
          if ! truncate -s "$DISK_SPACE" "$DISK_FILE"; then
            error "$FAIL" && exit 75
          fi
        fi

      fi
      ;;
    qcow2)
      if ! qemu-img resize -f "$DISK_FMT" "$DISK_FILE" "$DISK_SPACE" ; then
        error "$FAIL" && exit 72
      fi
      ;;
  esac
}

convertDisk() {
  local CONV_FLAGS="-p"
  local SOURCE_FILE=$1
  local SOURCE_FMT=$2
  local DST_FILE=$3
  local DST_FMT=$4

  case "$DST_FMT" in
    qcow2)
      CONV_FLAGS="$CONV_FLAGS -c"
      ;;
  esac

  # shellcheck disable=SC2086
  qemu-img convert $CONV_FLAGS -f "$SOURCE_FMT" -O "$DST_FMT" -- "$SOURCE_FILE" "$DST_FILE"
}

createDisk() {
  local DISK_FILE=$1
  local DISK_SPACE=$2
  local DISK_DESC=$3
  local DISK_FMT=$4
  local GB FAIL SPACE SPACE_GB

  FAIL="Could not create a $DISK_SPACE $DISK_FMT file for $DISK_DESC ($DISK_FILE)"

  case "${DISK_FMT,,}" in
    raw)
      if [[ "$ALLOCATE" == [Nn]* ]]; then

        # Create an empty file
        if ! truncate -s "$DISK_SPACE" "$DISK_FILE"; then
          rm -f "$DISK_FILE"
          error "$FAIL" && exit 77
        fi

      else

        # Check free diskspace
        SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)
        SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))

        if (( DATA_SIZE > SPACE )); then
          error "Not enough free space to create a $DISK_DESC of $DISK_SPACE in $DIR, it has only $SPACE_GB GB available.."
          error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting DISK_FMT to \"qcow2\"." && exit 76
        fi

        # Create an empty file
        if ! fallocate -l "$DISK_SPACE" "$DISK_FILE"; then
          if ! truncate -s "$DISK_SPACE" "$DISK_FILE"; then
            rm -f "$DISK_FILE"
            error "$FAIL" && exit 77
          fi
        fi

      fi
      ;;
    qcow2)
      if ! qemu-img create -f "$DISK_FMT" -- "$DISK_FILE" "$DISK_SPACE" ; then
        rm -f "$DISK_FILE"
        error "$FAIL" && exit 70
      fi
      ;;
  esac
}

addDisk () {
  local DISK_ID=$1
  local DISK_BASE=$2
  local DISK_EXT=$3
  local DISK_DESC=$4
  local DISK_SPACE=$5
  local DISK_INDEX=$6
  local DISK_ADDRESS=$7
  local DISK_FMT=$8
  local DIR CUR_SIZE DATA_SIZE DISK_FILE

  DISK_FILE="$DISK_BASE.$DISK_EXT"
  DIR=$(dirname "$DISK_FILE")
  [ ! -d "$DIR" ] && return 0

  [ -z "$DISK_SPACE" ] && DISK_SPACE="16G"
  DISK_SPACE=$(echo "$DISK_SPACE" | sed 's/MB/M/g;s/GB/G/g;s/TB/T/g')
  DATA_SIZE=$(numfmt --from=iec "$DISK_SPACE")

  if ! [ -f "$DISK_FILE" ] ; then
    local PREV_EXT PREV_FMT PREV_FILE TMP_FILE

    if [[ "${DISK_FMT,,}" != "raw" ]]; then
      PREV_FMT="raw"
    else
      PREV_FMT="qcow2"
    fi
    PREV_EXT="$(fmt2ext "$PREV_FMT")"
    PREV_FILE="$DISK_BASE.$PREV_EXT"

    if [ -f "$PREV_FILE" ] ; then

      info "Detected that ${DISK_DESC^^}_FMT changed from \"$PREV_FMT\" to \"$DISK_FMT\"."
      info "Starting conversion of $DISK_DESC to this new format, please wait until completed..."

      TMP_FILE="$DISK_BASE.tmp"
      rm -f "$TMP_FILE"

      if ! convertDisk "$PREV_FILE" "$PREV_FMT" "$TMP_FILE" "$DISK_FMT" ; then
        rm -f "$TMP_FILE"
        error "Failed to convert $DISK_DESC to $DISK_FMT format." && exit 79
      fi

      mv "$TMP_FILE" "$DISK_FILE"
      rm -f "$PREV_FILE"
      info "Conversion of $DISK_DESC completed succesfully!"
    fi
  fi

  if [ -f "$DISK_FILE" ]; then

    CUR_SIZE=$(getSize "$DISK_FILE")

    if [ "$DATA_SIZE" -gt "$CUR_SIZE" ]; then
      resizeDisk "$DISK_FILE" "$CUR_SIZE" "$DATA_SIZE" "$DISK_SPACE" "$DISK_DESC" "$DISK_FMT" || exit $?
    fi

  else

    createDisk "$DISK_FILE" "$DISK_SPACE" "$DISK_DESC" "$DISK_FMT" || exit $?

  fi

  DISK_OPTS="$DISK_OPTS \
    -device virtio-scsi-pci,id=hw-$DISK_ID,bus=pcie.0,addr=$DISK_ADDRESS \
    -drive file=$DISK_FILE,if=none,id=drive-$DISK_ID,format=$DISK_FMT,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,detect-zeroes=on \
    -device scsi-hd,bus=hw-$DISK_ID.0,channel=0,scsi-id=0,lun=0,drive=drive-$DISK_ID,id=$DISK_ID,rotation_rate=$DISK_ROTATION,bootindex=$DISK_INDEX"

  return 0
}

DISK_EXT="$(fmt2ext "$DISK_FMT")" || exit $?

DISK1_FILE="$STORAGE/data"
DISK2_FILE="/storage2/data2"
DISK3_FILE="/storage3/data3"
DISK4_FILE="/storage4/data4"
DISK5_FILE="/storage5/data5"
DISK6_FILE="/storage6/data6"

: ${DISK2_SIZE:=''}
: ${DISK3_SIZE:=''}
: ${DISK4_SIZE:=''}
: ${DISK5_SIZE:=''}
: ${DISK6_SIZE:=''}

addDisk "userdata" "$DISK1_FILE" "$DISK_EXT" "disk"  "$DISK_SIZE"  "1" "0xa" "$DISK_FMT" || exit $?
addDisk "userdata2" "$DISK2_FILE" "$DISK_EXT" "disk2" "$DISK2_SIZE" "2" "0xb" "$DISK_FMT" || exit $?
addDisk "userdata3" "$DISK3_FILE" "$DISK_EXT" "disk3" "$DISK3_SIZE" "3" "0xc" "$DISK_FMT" || exit $?
addDisk "userdata4" "$DISK4_FILE" "$DISK_EXT" "disk4" "$DISK4_SIZE" "4" "0xd" "$DISK_FMT" || exit $?
addDisk "userdata5" "$DISK5_FILE" "$DISK_EXT" "disk5" "$DISK5_SIZE" "5" "0xe" "$DISK_FMT" || exit $?
addDisk "userdata6" "$DISK6_FILE" "$DISK_EXT" "disk6" "$DISK6_SIZE" "6" "0xf" "$DISK_FMT" || exit $?

addDevice () {

  local DISK_ID=$1
  local DISK_DEV=$2
  local DISK_INDEX=$3
  local DISK_ADDRESS=$4

  [ -z "$DISK_DEV" ] && return 0
  [ ! -b "$DISK_DEV" ] && error "Device $DISK_DEV cannot be found! Please add it to the 'devices' section of your compose file." && exit 55

  DISK_OPTS="$DISK_OPTS \
    -device virtio-scsi-pci,id=hw-$DISK_ID,bus=pcie.0,addr=$DISK_ADDRESS \
    -drive file=$DISK_DEV,if=none,id=drive-$DISK_ID,format=raw,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,detect-zeroes=on \
    -device scsi-hd,bus=hw-$DISK_ID.0,channel=0,scsi-id=0,lun=0,drive=drive-$DISK_ID,id=$DISK_ID,rotation_rate=$DISK_ROTATION,bootindex=$DISK_INDEX"

  return 0
}

: ${DEVICE:=''}        # Docker variable to passthrough a block device, like /dev/vdc1.
: ${DEVICE2:=''}
: ${DEVICE3:=''}
: ${DEVICE4:=''}
: ${DEVICE5:=''}
: ${DEVICE6:=''}

addDevice "userdata7" "$DEVICE" "7" "0x6" || exit $?
addDevice "userdata8" "$DEVICE2" "8" "0x7" || exit $?
addDevice "userdata9" "$DEVICE3" "9" "0x8" || exit $?
addDevice "userdata4" "$DEVICE4" "4" "0xd" || exit $?
addDevice "userdata5" "$DEVICE5" "5" "0xe" || exit $?
addDevice "userdata6" "$DEVICE6" "6" "0xf" || exit $?

return 0