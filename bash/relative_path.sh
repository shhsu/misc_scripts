function loop_relative() {
  find_root=$1
  if [[ -z $find_root ]]; then
    find_root='.'
  fi

  find_root=${@%/}

  root_pattern=$(echo $find_root | sed "s/\//\\\\\//g")
  find $find_root -type f | sed "s/^$root_pattern\///g"
}
