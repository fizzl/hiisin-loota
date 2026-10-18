# hiisin-loota guest environment. Installed as /etc/profile.d/hiisin-loota.sh.
# Sourced by login shells and by the exec channel handler. Boot-derived values
# (proxy address) come from /run/hiisin-loota/env, written by hiisin-loota-net.
[ -r /run/hiisin-loota/env ] && { set -a; . /run/hiisin-loota/env; set +a; }
export HIISIN_LOOTA=1 IS_SANDBOX=1
# No updaters, no prompts: nothing in the guest can answer one.
export DISABLE_AUTOUPDATER=1 GH_NO_UPDATE_NOTIFIER=1
export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true GIT_ASKPASS=/bin/false
export DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1
export npm_config_update_notifier=false npm_config_fund=false COREPACK_ENABLE_AUTO_PIN=0
