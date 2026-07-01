# Cloudflare Security Fixes - Manual Steps
# ============================================
# These are the security fixes that need to be applied to fix
# Cloudflare Security Insights for reverb256.ca

# ISSUE 1: DMARC Record Error (14 occurrences)
# ============================================
# Create DMARC TXT record for reverb256.ca:
#
# reverb256.ca:
#   Type: TXT
#   Name: _dmarc
#   Content: v=DMARC1; p=reject; rua=mailto:dmarc@reverb256.ca; ruf=mailto:dmarc@reverb256.ca
#
# Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/dns
# Add the record manually

# ISSUE 2: Unproxied A Records (4 occurrences)
# ============================================
# Find A records with "DNS only" (gray cloud) and change to "Proxied" (orange cloud)
#
# These are exposing your origin IP. Enable Cloudflare proxy by:
# 1. Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/dns
# 2. Find A records pointing to 10.1.1.x IPs
# 3. Click the cloud icon to switch from gray (DNS only) to orange (Proxied)
#
# NOTE: Do NOT proxy .lan records - they should remain DNS-only

# ISSUE 3: Dangling A Records (4 occurrences)
# ============================================
# Remove A records that point to IPs with no running service
#
# Check these records and delete if unused:
# 1. Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/dns
# 2. Review A records - check if each IP has a service running
# 3. Delete unused records
#
# To identify dangling records, SSH to each IP and check services:
#   ssh j_kro@10.1.1.XX 'systemctl status | grep -i "loaded\|active"'

# ISSUE 4: Security.txt not configured (5 occurrences)
# ============================================
# Create security.txt file at /.well-known/security.txt
#
# Add this file to your web root:
#
# /var/www/html/reverb256.ca/.well-known/security.txt:
# --------------------------------------------------------
Contact: mailto:security@reverb256.ca
Contact: mailto:J_kroeker@reverb256.ca
Expires: 2027-07-01T00:00:00Z
Preferred-Languages: en, fr
Encryption: https://reverb256.ca/.well-known/pgp-key.asc
Acknowledgments: https://reverb256.ca/security/acknowledgments
Policy: https://reverb256.ca/security/policy
Hiring: https://reverb256.ca/security/jobs
CSAF: https://reverb256.ca/.well-known/csaf/provider-metadata.json
# --------------------------------------------------------

# ISSUE 5: AI Labyrinth not enabled (6 occurrences)
# ============================================
# AI Labyrinth is a Cloudflare security feature for protecting against AI scrapers
#
# Manual configuration required:
# 1. Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/security/ai-labyrinth
# 2. Enable AI Labyrinth
# 3. Configure challenge settings for AI bots
# 4. Enable blocking for known AI crawlers

# ISSUE 6: Block AI bots not enabled (5 occurrences)
# ============================================
# Create WAF rule to block AI bots
#
# Manual WAF rule creation:
# 1. Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/security/waf/custom-rules
# 2. Click "Create rule"
# 3. Name: "Block AI Bots"
# 4. Field: User Agent
# 5. Operator: Contains
# 6. Value: GPTBot
# 7. Action: Block
# 8. Add additional conditions for:
#    - CCbot
#    - Google-Extended
#    - anthropic
#    - ClaudeBot
#    - FacebookBot
#    - PerplexityBot
#    - YouBot
# 9. Save and deploy

# SUMMARY OF ACTIONS
# ===================
# 1. Add DMARC TXT record (1 record)
# 2. Enable proxy on unproxied A records (4 records)
# 3. Delete dangling A records (4 records)
# 4. Deploy security.txt file (1 file)
# 5. Enable AI Labyrinth (dashboard)
# 6. Create WAF rule for AI bots (1 rule)
#
# Total: 10 manual actions required

# VERIFICATION
# =============
# After completing all steps:
# 1. Go to: https://dash.cloudflare.com/9062487114ef5404de8de6689cb54895/security/insights
# 2. Run a new scan
# 3. All issues should be resolved