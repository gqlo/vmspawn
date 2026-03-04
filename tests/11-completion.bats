#!/usr/bin/env bats

# Tab completion smoke tests
# Run with: bats tests/

# No oc mock needed -- completion script does not call oc

# ---------------------------------------------------------------
# COMP-1: completion script exists
# ---------------------------------------------------------------
@test "COMP: tab-completion script exists" {
	[[ -f tab-completion/vstorm.bash ]]
	[[ -r tab-completion/vstorm.bash ]]
}

# ---------------------------------------------------------------
# COMP-2: completion script registers vstorm completion
# ---------------------------------------------------------------
@test "COMP: completion script registers vstorm completion" {
	run bash -c "source tab-completion/vstorm.bash && complete -p vstorm"
	[ "$status" -eq 0 ]
	[[ "$output" == *"_vstorm"* ]]
	[[ "$output" == *"vstorm"* ]]
}

# ---------------------------------------------------------------
# COMP-3: --de completes to --delete and --delete-all
# ---------------------------------------------------------------
@test "COMP: --de completes to --delete and --delete-all" {
	run bash -c '
		source tab-completion/vstorm.bash
		COMP_WORDS=(vstorm --de)
		COMP_CWORD=1
		_vstorm
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
	echo "source $(pwd)/tab-completion/vstorm.bash" >> "$tmp"
	run bash -c "source $tmp 2>&1"
	rm -f "$tmp"
	[ "$status" -eq 0 ]
}
