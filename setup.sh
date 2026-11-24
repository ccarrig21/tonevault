#!/bin/bash
# Usage: ./setup.sh com.yourname   (sets bundle IDs + app group)
set -e
[ -z "$1" ] && { echo "usage: ./setup.sh com.yourname"; exit 1; }
perl -pi -e "s/com\.example/$1/g" project.yml Sources/Shared/Config.swift
echo "Bundle prefix set to $1  (app group: group.$1.tonevault)"
