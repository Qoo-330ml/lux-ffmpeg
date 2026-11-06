#!/usr/bin/env bash
#
# lux/build/apply-patches.sh — 管理 lux 补丁集(lux/patches/ + lux/config/patches.txt)
#
#   apply-patches.sh status     每个补丁的状态(已应用 / 未应用)
#   apply-patches.sh apply      工作区必须干净;按 patches.txt 顺序零 fuzz 应用
#   apply-patches.sh revert     逆序回滚
#   apply-patches.sh check      临时全量应用一遍再回滚(验收用,不改动结果)
#   apply-patches.sh ensure     一个没打就 apply;全打了就跳过;部分打就报错
#   apply-patches.sh digest     补丁集指纹,写进 BUILD-INFO / 许可记录
#   apply-patches.sh count      补丁条数
#   apply-patches.sh applied    全部已应用时退出 0
#
# 设计约束:
#   * 只用 `git apply`(默认 0 fuzz,不加 -C/-3)。补丁漂移就重新生成,不靠模糊匹配。
#   * 工作区有未提交改动时拒绝 apply/check/ensure 的写操作,避免把冲突掩盖掉。
#   * 只改源码树;lux/** 由 git 跟踪,不参与补丁。
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LUX=$(cd "$HERE/.." && pwd)
REPO=$(cd "$LUX/.." && pwd)
PATCHDIR=${LUX_PATCHDIR:-$LUX/patches}
LIST=${LUX_PATCHLIST:-$LUX/config/patches.txt}

die() { printf 'apply-patches: %s\n' "$*" >&2; exit 1; }
gitx() { git -C "$REPO" "$@"; }

patch_list() {
    # 去掉注释与空行,只保留第一个字段
    sed -e 's/#.*//' "$LIST" | awk 'NF { print $1 }'
}

dirty() {
    # lux/** 是我们自己的工具与补丁文件,不参与补丁应用,所以不算"脏"。
    [ -n "$(gitx status --porcelain --untracked-files=no -- . ':(exclude)lux' 2>/dev/null)" ]
}

is_applied() {
    gitx apply -R --check "$PATCHDIR/$1" >/dev/null 2>&1
}

cmd="${1:-status}"

[ -r "$LIST" ] || die "找不到补丁清单: $LIST"
[ -d "$PATCHDIR" ] || die "找不到补丁目录: $PATCHDIR"

case "$cmd" in
    status)
        n=0
        while IFS= read -r p; do
            [ -f "$PATCHDIR/$p" ] || die "缺少补丁文件: $PATCHDIR/$p"
            n=$((n + 1))
            if is_applied "$p"; then
                printf '[applied]     %s\n' "$p"
            else
                printf '[not applied] %s\n' "$p"
            fi
        done < <(patch_list)
        printf 'total: %d\n' "$n"
        ;;

    count)
        patch_list | wc -l | tr -d ' '
        ;;

    digest)
        {
            while IFS= read -r p; do
                [ -f "$PATCHDIR/$p" ] || die "缺少补丁文件: $PATCHDIR/$p"
                printf 'patch %s\n' "$p"
                shasum -a 256 "$PATCHDIR/$p" | awk '{ print $1 }'
            done < <(patch_list)
        } | shasum -a 256 | awk '{ print $1 }'
        ;;

    applied)
        while IFS= read -r p; do
            is_applied "$p" || die "尚未应用: $p"
        done < <(patch_list)
        exit 0
        ;;

    apply)
        dirty && die "工作区有未提交改动,先 commit 或 stash 再 apply"
        while IFS= read -r p; do
            [ -f "$PATCHDIR/$p" ] || die "缺少补丁文件: $PATCHDIR/$p"
            is_applied "$p" && die "已经应用过: $p"
            gitx apply "$PATCHDIR/$p" || die "应用失败(补丁需要重新生成?): $p"
            printf '[apply] %s\n' "$p"
        done < <(patch_list)
        ;;

    revert)
        local_patches=()
        while IFS= read -r p; do local_patches+=("$p"); done < <(patch_list)
        for (( i = ${#local_patches[@]} - 1; i >= 0; i-- )); do
            p=${local_patches[$i]}
            if ! is_applied "$p"; then
                printf '[skip]  未应用,忽略: %s\n' "$p"
                continue
            fi
            gitx apply -R "$PATCHDIR/$p" || die "回滚失败: $p"
            printf '[revert] %s\n' "$p"
        done
        ;;

    check)
        dirty && die "工作区有未提交改动,先 commit 或 stash 再 check"
        applied_so_far=()
        ok=0
        while IFS= read -r p; do
            [ -f "$PATCHDIR/$p" ] || { printf '[FAIL] 缺少补丁文件: %s\n' "$p" >&2; ok=1; break; }
            if gitx apply "$PATCHDIR/$p" 2>/dev/null; then
                applied_so_far+=("$p")
                printf '[ok]   %s\n' "$p"
            else
                printf '[FAIL] 无法零 fuzz 应用: %s\n' "$p" >&2
                ok=1
                break
            fi
        done < <(patch_list)

        # 无论成败都回滚,保持工作区干净
        for (( i = ${#applied_so_far[@]} - 1; i >= 0; i-- )); do
            gitx apply -R "$PATCHDIR/${applied_so_far[$i]}" >/dev/null 2>&1 \
                || printf '[warn] 回滚失败,请检查工作区: %s\n' "${applied_so_far[$i]}" >&2
        done

        [ "$ok" -eq 0 ] || die "补丁集 check 失败"
        printf 'RESULT: PASS (%s patches)\n' "$(patch_list | wc -l | tr -d ' ')"
        ;;

    ensure)
        total=0
        have=0
        while IFS= read -r p; do
            total=$((total + 1))
            is_applied "$p" && have=$((have + 1))
        done < <(patch_list)

        if [ "$have" -eq "$total" ]; then
            printf '[ensure] 补丁集已应用(%d/%d)\n' "$have" "$total"
            exit 0
        fi
        if [ "$have" -ne 0 ]; then
            die "补丁集只应用了 $have/$total,状态不一致;先 revert 再 apply"
        fi
        exec "$0" apply
        ;;

    *)
        die "未知子命令: $cmd(可用: status|apply|revert|check|ensure|digest|count|applied)"
        ;;
esac
