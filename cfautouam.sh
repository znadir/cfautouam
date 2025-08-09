#!/bin/bash
# Cloudflare Auto Under Attack Mode = CF Auto UAM
# version 0.99beta

# Security Level Enums
SL_OFF=0
SL_ESSENTIALLY_OFF=1
SL_LOW=2
SL_MEDIUM=3
SL_HIGH=4
SL_UNDER_ATTACK=5

# Security Level Strings
SL_OFF_S="off"
SL_ESSENTIALLY_OFF_S="essentially_off"
SL_LOW_S="low"
SL_MEDIUM_S="medium"
SL_HIGH_S="high"
SL_UNDER_ATTACK_S="under_attack"

#config
debug_mode=0 # 1 = true, 0 = false, adds more logging & lets you edit vars to test the script
install_parent_path="/home"
cf_apikey=""
cf_zoneid=""
upper_cpu_limit=35 # 10 = 10% load, 20 = 20% load.  Total load, taking into account # of cores
lower_cpu_limit=5
regular_status=$SL_HIGH
regular_status_s=$SL_HIGH_S
time_limit_before_revert=$((60 * 5)) # 5 minutes by default
#end config

# Functions

install() {
  mkdir $install_parent_path"/cfautouam" &>/dev/null

  cat >$install_parent_path"/cfautouam/cfautouam.service" <<EOF
[Unit]
Description=Automate Cloudflare Under Attack Mode
[Service]
ExecStart=$install_parent_path/cfautouam/cfautouam.sh
EOF

  cat >$install_parent_path"/cfautouam/cfautouam.timer" <<EOF
[Unit]
Description=Automate Cloudflare Under Attack Mode
[Timer]
OnBootSec=60
OnUnitActiveSec=5
AccuracySec=1
[Install]
WantedBy=timers.target
EOF

  chmod +x $install_parent_path"/cfautouam/cfautouam.service"
  systemctl enable $install_parent_path"/cfautouam/cfautouam.timer"
  systemctl enable $install_parent_path"/cfautouam/cfautouam.service"
  systemctl start cfautouam.timer
  echo "$(date) - cfautouam - Installed" >>$install_parent_path"/cfautouam/cfautouam.log"
  exit
}

uninstall() {
  systemctl stop cfautouam.timer
  systemctl stop cfautouam.service
  systemctl disable cfautouam.timer
  systemctl disable cfautouam.service
  rm $install_parent_path"/cfautouam/cfstatus" &>/dev/null
  rm $install_parent_path"/cfautouam/uamdisabledtime" &>/dev/null
  rm $install_parent_path"/cfautouam/uamenabledtime" &>/dev/null
  rm $install_parent_path"/cfautouam/cfautouam.timer"
  rm $install_parent_path"/cfautouam/cfautouam.service"
  echo "$(date) - cfautouam - Uninstalled" >>$install_parent_path"/cfautouam/cfautouam.log"
  exit
}

disable_uam() {
  curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$cf_zoneid/settings/security_level" \
    -H "Authorization: Bearer $cf_apikey" \
    -H "Content-Type: application/json" \
    --data "{\"value\":\"$regular_status_s\"}" &>/dev/null

  # log time
  date +%s >$install_parent_path"/cfautouam/uamdisabledtime"

  echo "$(date) - cfautouam - CPU Load: $curr_load - Disabled UAM" >>$install_parent_path"/cfautouam/cfautouam.log"
}

enable_uam() {
  curl -X PATCH "https://api.cloudflare.com/client/v4/zones/$cf_zoneid/settings/security_level" \
    -H "Authorization: Bearer $cf_apikey" \
    -H "Content-Type: application/json" \
    --data '{"value":"under_attack"}' &>/dev/null

  # log time
  date +%s >$install_parent_path"/cfautouam/uamenabledtime"

  echo "$(date) - cfautouam - CPU Load: $curr_load - Enabled UAM" >>$install_parent_path"/cfautouam/cfautouam.log"
}

get_current_load() {
  currload=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
  currload=$(echo "$currload/1" | bc)
  return $currload
}

get_security_level() {
  curl -X GET "https://api.cloudflare.com/client/v4/zones/$cf_zoneid/settings/security_level" \
    -H "Authorization: Bearer $cf_apikey" \
    -H "Content-Type: application/json" 2>/dev/null |
    awk -F":" '{ print $4 }' | awk -F',' '{ print $1 }' | tr -d '"' >$install_parent_path"/cfautouam/cfstatus"

  security_level=$(cat $install_parent_path"/cfautouam/cfstatus")

  case $security_level in
  "off")
    return $SL_OFF
    ;;
  "essentially_off")
    return $SL_ESSENTIALLY_OFF
    ;;
  "low")
    return $SL_LOW
    ;;
  "medium")
    return $SL_MEDIUM
    ;;
  "high")
    return $SL_HIGH
    ;;
  "under_attack")
    return $SL_UNDER_ATTACK
    ;;
  *)
    return 100 # error
    ;;
  esac
}

main() {
  # Get current protection level & load
  get_security_level
  curr_security_level=$?
  get_current_load
  curr_load=$?

  if [ $debug_mode == 1 ]; then
    debug_mode=1 # random inconsequential line needed to hide a dumb shellcheck error
        #edit vars here to debug the script
    #curr_load=5
    #time_limit_before_revert=15
  fi

  # If UAM was recently enabled

  if [[ $curr_security_level == "$SL_UNDER_ATTACK" ]]; then
    uam_enabled_time=$(<$install_parent_path"/cfautouam/uamenabledtime")
    currenttime=$(date +%s)
    timediff=$((currenttime - uam_enabled_time))

    # If time limit has not passed do nothing
    if [[ $timediff -lt $time_limit_before_revert ]]; then
        if [ $debug_mode == 1 ]; then
          echo "$(date) - cfautouam - CPU Load: $curr_load - time limit has not passed regardless of CPU - do nothing" >>$install_parent_path"/cfautouam/cfautouam.log"
        fi
        exit
    fi

    # If time limit has passed & cpu load has normalized, then disable UAM
    if [[ $timediff -gt $time_limit_before_revert && $curr_load -lt $lower_cpu_limit ]]; then
        if [ $debug_mode == 1 ]; then
          echo "$(date) - cfautouam - CPU Load: $curr_load - time limit has passed - CPU Below threshhold" >>$install_parent_path"/cfautouam/cfautouam.log"
        fi
        disable_uam
        exit
    fi

    # If time limit has passed & cpu load has not normalized, wait
    if [[ $timediff -gt $time_limit_before_revert && $curr_load -gt $lower_cpu_limit ]]; then
      if [ $debug_mode == 1 ]; then
        echo "$(date) - cfautouam - CPU Load: $curr_load - time limit has passed but CPU above threshhold, waiting out time limit" >>$install_parent_path"/cfautouam/cfautouam.log"
      fi
    fi
    exit
  fi

  # If UAM is not enabled, continue

  # Enable and Disable UAM based on load

  #if load is higher than limit
  if [[ $curr_load -gt $upper_cpu_limit && $curr_security_level == "$regular_status" ]]; then
    enable_uam
  #else if load is lower than limit
  elif [[ $curr_load -lt $lower_cpu_limit && $curr_security_level == "$SL_UNDER_ATTACK" ]]; then
    disable_uam
  else
    if [ $debug_mode == 1 ]; then
      echo "$(date) - cfautouam - CPU Load: $curr_load - no change necessary" >>$install_parent_path"/cfautouam/cfautouam.log"
    fi
  fi
}

# End Functions

# Main -> command line arguments

if [ "$1" = '-install' ]; then
  install
  echo "$(date) - cfautouam - Installed" >>$install_parent_path"/cfautouam/cfautouam.log"
  exit
elif [ "$1" = '-uninstall' ]; then
  uninstall
  echo "$(date) - cfautouam - Uninstalled" >>$install_parent_path"/cfautouam/cfautouam.log"
  exit
elif [ "$1" = '-enable_uam' ]; then
  echo "$(date) - cfautouam - UAM Manually Enabled" >>$install_parent_path"/cfautouam/cfautouam.log"
  enable_uam
  exit
elif [ "$1" = '-disable_uam' ]; then
  echo "$(date) - cfautouam - UAM Manually Disabled" >>$install_parent_path"/cfautouam/cfautouam.log"
  disable_uam
  exit
elif [ -z "$1" ]; then
  main
  exit
else
  echo "cfautouam - Invalid argument"
  exit
fi
