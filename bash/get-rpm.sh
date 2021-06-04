#!/bin/bash -e
# script to download specific rpm file from a repo by looking at the repo directory html page

repo_dir=$1
package_name=$2
destination=$3

if [[ -z "$repo_dir" ]]; then
    >&2 echo "Repo Dir needed"
    exit 1
fi

if [[ -z "$package_name" ]]; then
    >&2 echo "Package name needed"
    exit 1
fi

if [[ -z "$destination" ]]; then
    >&2 echo "Destination needed"
    exit 1
fi

download_link=$(curl -k -s -L $repo_dir | sed -n 's/.*href="\([^"]*\).*/\1/p' | grep -e "^\(.*/\)\?$package_name-[0-9]" | sort | tail -1)

if [[ -z $download_link ]]; then
    >&2 echo "Download link not found"
    exit 1
fi

if [[ $download_link =~ "://" ]]; then
    download_url=$download_link
else
    download_url=${repo_dir%/}/$download_link
fi

cd $destination
echo "Downloading from $download_url to $destination"
curl -k -s -L $download_url -O
echo "Done"
