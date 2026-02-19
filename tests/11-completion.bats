#!/usr/bin/env bats

# Tab completion smoke tests
# Run with: bats tests/

# No oc mock needed -- completion script does not call oc

# ---------------------------------------------------------------
# COMP-1: completion script exists
# ---------------------------------------------------------------
@test "COMP: tab-completion script exists" {
	[[ -f tab-completion/vmspawn.bash ]]
	[[ -r tab-completion/vmspawn.bash ]]
}

# ---------------------------------------------------------------
# COMP-2: completion script registers vmspawn completion
# ---------------------------------------------------------------
@test "COMP: completion script registers vmspawn completion" {
	run bash -c "source tab-completion/vmspawn.bash && complete -p vmspawn"
	[ "$status" -eq 0 ]
	[[ "$output" == *"_vmspawn"* ]]
	[[ "$output" == *"vmspawn"* ]]
}

# ---------------------------------------------------------------
# COMP-3: --de completes to --delete and --delete-all
# ---------------------------------------------------------------
@test "COMP: --de completes to --delete and --delete-all" {
	run bash -c '
		source tab-completion/vmspawn.bash
		COMP_WORDS=(vmspawn --de)
		COMP_CWORD=1
		_vmspawn
		echo "${COMPREPLY[@]}"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"--delete"* ]]
	[[ "$output" == *"--delete-all"* ]]
}

# ---------------------------------------------------------------
# COMP-4: setup echo commands produce valid bashrc lines
# ---------------------------------------------------------------
@test "COMP: setup echo commands produce valid bashrc lines" {
	tmp=$(mktemp)
	echo "export PATH=\"$(pwd):\$PATH\"" >> "$tmp"
	echo "source $(pwd)/tab-completion/vmspawn.bash" >> "$tmp"
	run bash -c "source $tmp 2>&1"
	rm -f "$tmp"
	[ "$status" -eq 0 ]
}
