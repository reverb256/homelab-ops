G1: Fork exists on GitHub  |  CHECK: gh repo view reverb256/infomarchy --json name 2>/dev/null | jq -r '.name'  |  EXPECT: infomarchy
G2: Local fork clone exists  |  CHECK: test -d /home/jro/Projects/infomarchy-fork/.git && echo ok  |  EXPECT: ok
G3: All Infomarchy changes committed  |  CHECK: cd /home/j_kro/Projects/infomarchy-fork && git status --porcelain | wc -l  |  EXPECT: 0
G4: Changes pushed to fork  |  CHECK: cd /home/j_kro/Projects/infomarchy-fork && git log --oneline -1 origin/main..HEAD 2>/dev/null | wc -l  |  EXPECT: 0
G5: PR opened against upstream  |  CHECK: cd /home/j_kro/Projects/infomarchy-fork && gh pr list --state open --limit 1 --json number | jq -r '.[0].number'  |  EXPECT: /[0-9]+/
