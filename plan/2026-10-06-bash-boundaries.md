# Bash recognition boundaries

The audit found missed destructive commands and false denials caused by separate
regular expressions interpreting newlines, quotes, redirections, and heredocs
differently. Fix their shared lexical boundary without expanding the policy.

- Decode simple words once per pass, retaining raw spelling and HOME/tilde origin.
- Emit explicit command boundaries and complete redirections, including an
  unquoted IO_NUMBER. Redirection operands never become command arguments.
- Use the same tokens to collect complete heredoc delimiters after quote removal;
  escaped operators are words, not heredoc starts.
- Preserve the existing git/rm policies and wrapper spellings. No shell execution,
  substitutions, arbitrary grammar, or filesystem resolution is introduced.

Verification covers both native JSON protocols and classifier equivalences:
independent preceding commands, inserted redirections, quoted printing commands,
and real versus escaped heredoc headers. All proposed commands remain inert test
strings. Existing continuation and HOME tests must continue to pass.
