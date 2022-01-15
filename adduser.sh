#!/bin/bash

users=("$1")
for username in $users; do
    # 対話式でメールアカウントとか聞かれないように-gecos ""指定
    # パスワードは後でchpasswdで設定するのでdisable
    adduser --disabled-password --gecos "" "$username"

    # 非対話でパスワード設定（初期パスワードをユーザ名と同じにする）
    echo "${username}:${username}123!" | chpasswd

    # sudo 権限付与
    gpasswd -a "$username" sudo
done
