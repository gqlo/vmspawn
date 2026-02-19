# Bash tab completion for vmspawn
# Source this file to enable: source tab-completion/vmspawn.bash
# Or add to .bashrc: source /path/to/vmspawn/tab-completion/vmspawn.bash

_vmspawn() {
	local cur=${COMP_WORDS[COMP_CWORD]}
	local opts=(
		-n -q -y -h
		--help
		--datasource= --dv-url= --storage-size= --storage-class=
		--access-mode= --rwx --rwo
		--snapshot-class= --snapshot --no-snapshot
		--pvc-base-name= --batch-id= --basename=
		--cores= --memory= --request-memory= --request-cpu=
		--vms= --vms-per-namespace= --namespaces=
		--run-strategy=
		--create-existing-vm --wait --nowait --start --stop
		--containerdisk --containerdisk=
		--cloudinit= --profile --profile=
		--delete= --delete-all --yes
	)

	# Complete option names when current word starts with - or --
	if [[ "$cur" == -* ]]; then
		COMPREPLY=( $(compgen -W "${opts[*]}" -- "$cur") )
	fi
}

complete -F _vmspawn vmspawn
