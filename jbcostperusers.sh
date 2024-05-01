#!/bin/bash

# 設定：1ノードあたりの時間単位の価格
COST_PER_NODE_HOUR=793 #JPY

# 結果を保存するファイル
output_file="job_costs.txt"

# ヘッダーをファイルに書き込む
echo "User,JobID,NodeCount,Walltime,Cost" > $output_file

# tracejobコマンドで取得するジョブIDの範囲を指定
start_job_id=0
end_job_id=30

# ユーザごとの総コストを保存する連想配列
declare -A user_costs

# 指定されたジョブID範囲でループ
for (( job_id=$start_job_id; job_id<=$end_job_id; job_id++ ))
do
  # tracejobの出力から必要な情報を抽出
  job_info=$(tracejob $job_id 2>&1)

  # ユーザー名を抽出
  user=$(echo "$job_info" | grep "Job Queued at request of" | awk '{print $12}' | awk -F "@" '{print $1}')
  user=${user:-"Unknown"}  # ユーザー名が空の場合は "Unknown" とする

  # ノード数を抽出
  nodes=$(echo "$job_info" | grep "exec_vnode" | grep -oP 'ip-\w+:\w+' | cut -d: -f 1)
  # ユニークなノードをカウント
  unique_nodes=$(echo "$nodes" | sort -u | wc -l)
  # ユニークなノード数を表示
  #echo "Unique node count: $unique_nodes"

  # 実行時間を抽出
  walltime=$(echo "$job_info" | grep "resources_used.walltime" | awk '{print $10}' | awk -F "=" '{print $2}')

  # 実行時間を時間に変換（空白チェックを追加）
  if [[ -n "$walltime" && "$unique_nodes" -ne 0 ]]; then
    hours=$(echo $walltime | awk -F ":" '{print $1 + $2 / 60 + $3 / 3600}')
    # コスト計算前にデバッグ情報を表示
    echo "Calculating cost for $user: Hours = $hours, Nodes = $unique_nodes"
    # コストを計算（0時間でもエラーが出ないように修正）
    cost=$(echo "$hours * $unique_nodes * $COST_PER_NODE_HOUR" | bc -l)
    user_costs["$user"]=$(echo "${user_costs[$user]:-0} + $cost" | bc -l)
  else
    cost="N/A"
  fi

  # 結果をファイルに書き込む
  echo "$user,$job_id,$node_count,$walltime,$cost" >> $output_file
done

# 各ユーザの総コストを表示
for user in "${!user_costs[@]}"
do
  echo "Total cost for $user: ${user_costs[$user]} JPY"
done

echo "Cost calculation is complete."
