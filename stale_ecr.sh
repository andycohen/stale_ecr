#!/bin/bash

# ECR Unused Images Cleanup Script with CloudTrail Integration
# Identifies ECR images that haven't been pulled in over 6 months using actual pull data
# Usage: ./ecr-cleanup.sh [--dry-run] [--region us-east-1] [--registry-id 123456789012]

set -e

# Default values
DRY_RUN=false
REGION=""
REGISTRY_ID=""
CUTOFF_DAYS=180  # 6 months
OUTPUT_FILE="ecr-unused-images-$(date +%Y%m%d-%H%M%S).txt"
DELETE_SCRIPT="ecr-delete-unused-$(date +%Y%m%d-%H%M%S).sh"
CLOUDTRAIL_CACHE="cloudtrail-cache-$(date +%Y%m%d).json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --dry-run              Only identify unused images, don't create delete script"
    echo "  --region REGION        AWS region (default: uses AWS CLI default)"
    echo "  --registry-id ID       ECR registry ID (default: uses current account)"
    echo "  --days DAYS            Days threshold for unused images (default: 180)"
    echo "  --cache-only           Use existing CloudTrail cache file only"
    echo "  --no-cache             Skip cache, always fetch fresh CloudTrail data"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run"
    echo "  $0 --region us-west-2 --days 90"
    echo "  $0 --registry-id 123456789012"
    echo ""
    echo "Note: This script requires CloudTrail to be enabled with ECR API logging."
    echo "It looks for BatchGetImage and GetDownloadUrlForLayer events to determine actual pull dates."
}

# Parse command line arguments
CACHE_ONLY=false
NO_CACHE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --registry-id)
            REGISTRY_ID="$2"
            shift 2
            ;;
        --days)
            CUTOFF_DAYS="$2"
            shift 2
            ;;
        --cache-only)
            CACHE_ONLY=true
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Build AWS CLI command options
AWS_OPTS=""
if [[ -n "$REGION" ]]; then
    AWS_OPTS="$AWS_OPTS --region $REGION"
    CURRENT_REGION="$REGION"
else
    CURRENT_REGION=$(aws configure get region)
fi

if [[ -n "$REGISTRY_ID" ]]; then
    AWS_OPTS="$AWS_OPTS --registry-id $REGISTRY_ID"
fi

# Calculate cutoff date
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    CUTOFF_DATE=$(date -v-${CUTOFF_DAYS}d +%s)
    CUTOFF_ISO=$(date -v-${CUTOFF_DAYS}d -u +"%Y-%m-%dT%H:%M:%SZ")
else
    # Linux
    CUTOFF_DATE=$(date -d "${CUTOFF_DAYS} days ago" +%s)
    CUTOFF_ISO=$(date -d "${CUTOFF_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
fi

echo -e "${BLUE}ECR Unused Images Cleanup Script (CloudTrail Integration)${NC}"
echo -e "Cutoff: ${CUTOFF_DAYS} days ($(date -d "@$CUTOFF_DATE" 2>/dev/null || date -r "$CUTOFF_DATE"))"
echo -e "Region: ${CURRENT_REGION}"
echo -e "Registry ID: ${REGISTRY_ID:-current account}"
echo ""

# Check dependencies
for cmd in aws jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Please install $cmd first.${NC}"
        exit 1
    fi
done

# Check AWS credentials
if ! aws sts get-caller-identity $AWS_OPTS &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or invalid.${NC}"
    exit 1
fi

# Get current account ID if not provided
if [[ -z "$REGISTRY_ID" ]]; then
    REGISTRY_ID=$(aws sts get-caller-identity $AWS_OPTS --query 'Account' --output text)
fi

# Function to show spinning progress indicator
show_progress() {
    local pid=$1
    local message="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %10 ))
        printf "\r${YELLOW}%s %c${NC}" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r%s... ${GREEN}Done${NC}\n" "$message"
}

# Function to fetch CloudTrail events with progress tracking
fetch_cloudtrail_events() {
    echo -e "${YELLOW}Fetching CloudTrail events for ECR pulls...${NC}"
    echo "This may take several minutes depending on the volume of events."
    
    local temp_file=$(mktemp)
    local start_time="$CUTOFF_ISO"
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "Searching CloudTrail from $start_time to $end_time"
    echo ""
    
    # Try CloudWatch Logs first
    echo -e "${BLUE}Step 1/3: Attempting CloudWatch Logs query...${NC}"
    
    (aws logs start-query $AWS_OPTS \
        --log-group-name "CloudTrail/ECREvents" \
        --start-time $(date -d "$start_time" +%s) \
        --end-time $(date -d "$end_time" +%s) \
        --query-string 'fields @timestamp, eventName, sourceIPAddress, userIdentity.type, requestParameters, responseElements
        | filter eventName in ["BatchGetImage", "GetDownloadUrlForLayer"]
        | filter requestParameters.repositoryName exists
        | sort @timestamp desc' > /dev/null 2>&1) &
    
    local logs_pid=$!
    show_progress $logs_pid "Querying CloudWatch Logs"
    
    if wait $logs_pid; then
        echo -e "${GREEN}CloudWatch Logs query successful${NC}"
    else
        echo -e "${YELLOW}CloudWatch Logs not available, falling back to CloudTrail API...${NC}"
        echo ""
        
        # Fallback to CloudTrail API with progress tracking
        echo -e "${BLUE}Step 2/3: Fetching BatchGetImage events...${NC}"
        
        (aws cloudtrail lookup-events $AWS_OPTS \
            --lookup-attributes AttributeKey=EventName,AttributeValue=BatchGetImage \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --query 'Events[].{Time:EventTime,EventName:EventName,Resources:Resources,CloudTrailEvent:CloudTrailEvent}' \
            --output json > "${temp_file}.batch") &
        
        local batch_pid=$!
        show_progress $batch_pid "Fetching BatchGetImage events"
        wait $batch_pid
        
        local batch_count=$(jq length "${temp_file}.batch" 2>/dev/null || echo "0")
        echo -e "  Found ${GREEN}$batch_count${NC} BatchGetImage events"
        
        echo -e "${BLUE}Step 3/3: Fetching GetDownloadUrlForLayer events...${NC}"
        
        (aws cloudtrail lookup-events $AWS_OPTS \
            --lookup-attributes AttributeKey=EventName,AttributeValue=GetDownloadUrlForLayer \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --query 'Events[].{Time:EventTime,EventName:EventName,Resources:Resources,CloudTrailEvent:CloudTrailEvent}' \
            --output json > "${temp_file}.download") &
        
        local download_pid=$!
        show_progress $download_pid "Fetching GetDownloadUrlForLayer events"
        wait $download_pid
        
        local download_count=$(jq length "${temp_file}.download" 2>/dev/null || echo "0")
        echo -e "  Found ${GREEN}$download_count${NC} GetDownloadUrlForLayer events"
        
        echo -e "${BLUE}Combining and processing events...${NC}"
        
        # Combine and process events with progress
        (jq -s 'add | map(select(.CloudTrailEvent != null) | .CloudTrailEvent = (.CloudTrailEvent | fromjson))' \
            "${temp_file}.batch" "${temp_file}.download" > "$temp_file") &
        
        local combine_pid=$!
        show_progress $combine_pid "Processing CloudTrail data"
        wait $combine_pid
        
        rm -f "${temp_file}.batch" "${temp_file}.download"
        
        local total_events=$(jq length "$temp_file" 2>/dev/null || echo "0")
        echo -e "  Total events to process: ${GREEN}$total_events${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Processing CloudTrail data into cache format...${NC}"
    
    # Process and cache the events with progress indication
    if [[ -s "$temp_file" ]]; then
        echo -n "Analyzing events and grouping by repository... "
        
        # Extract relevant information and create cache format
        (jq -r '
        map(select(.CloudTrailEvent.requestParameters.repositoryName != null)) |
        map({
            timestamp: (.Time // .CloudTrailEvent.eventTime),
            repository: .CloudTrailEvent.requestParameters.repositoryName,
            imageId: (.CloudTrailEvent.requestParameters.imageIds[0] // {}),
            registryId: (.CloudTrailEvent.requestParameters.registryId // ""),
            sourceIP: (.CloudTrailEvent.sourceIPAddress // ""),
            userType: (.CloudTrailEvent.userIdentity.type // "")
        }) |
        group_by(.repository) |
        map({
            repository: .[0].repository,
            lastPull: (map(.timestamp) | max),
            pullCount: length,
            registryId: .[0].registryId
        })
        ' "$temp_file" > "$CLOUDTRAIL_CACHE") &
        
        local process_pid=$!
        show_progress $process_pid "Creating repository cache"
        wait $process_pid
        
        rm -f "$temp_file"
        
        # Show summary of cached data
        local repo_count=$(jq length "$CLOUDTRAIL_CACHE" 2>/dev/null || echo "0")
        local total_pulls=$(jq '[.[].pullCount] | add' "$CLOUDTRAIL_CACHE" 2>/dev/null || echo "0")
        
        echo -e "${GREEN}✓ CloudTrail analysis complete${NC}"
        echo -e "  Repositories with pull data: ${GREEN}$repo_count${NC}"
        echo -e "  Total pull events processed: ${GREEN}$total_pulls${NC}"
        echo -e "  Cache saved to: ${YELLOW}$CLOUDTRAIL_CACHE${NC}"
    else
        echo -e "${RED}✗ No CloudTrail events found${NC}"
        echo -e "${RED}Ensure CloudTrail is enabled for ECR API calls.${NC}"
        echo ""
        echo "To enable CloudTrail for ECR:"
        echo "1. Go to CloudTrail console"
        echo "2. Create or edit a trail"
        echo "3. Ensure 'Data events' are enabled for ECR"
        echo "4. Wait for events to accumulate (may take time)"
        exit 1
    fi
}

# Function to get last pull date for a repository
get_last_pull_date() {
    local repo="$1"
    local last_pull=""
    
    if [[ -f "$CLOUDTRAIL_CACHE" ]]; then
        last_pull=$(jq -r --arg repo "$repo" '.[] | select(.repository == $repo) | .lastPull // empty' "$CLOUDTRAIL_CACHE")
    fi
    
    echo "$last_pull"
}

# Handle CloudTrail data fetching
if [[ "$CACHE_ONLY" = true ]]; then
    if [[ ! -f "$CLOUDTRAIL_CACHE" ]]; then
        echo -e "${RED}Error: Cache file $CLOUDTRAIL_CACHE not found. Run without --cache-only first.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Using cached CloudTrail data: $CLOUDTRAIL_CACHE${NC}"
elif [[ "$NO_CACHE" = true ]] || [[ ! -f "$CLOUDTRAIL_CACHE" ]]; then
    fetch_cloudtrail_events
else
    echo -e "${YELLOW}Using existing CloudTrail cache: $CLOUDTRAIL_CACHE${NC}"
    echo "Use --no-cache to fetch fresh data or --cache-only to ensure using cache only"
fi

echo -e "${YELLOW}Scanning ECR repositories...${NC}"

# Initialize counters
TOTAL_IMAGES=0
UNUSED_IMAGES=0
NO_PULL_DATA_IMAGES=0
TOTAL_SIZE=0

# Create output files
{
    echo "# ECR Unused Images Report - $(date)"
    echo "# Images not pulled in over $CUTOFF_DAYS days (based on CloudTrail data)"
    echo "# Registry: $REGISTRY_ID, Region: $CURRENT_REGION"
    echo "# CloudTrail cache: $CLOUDTRAIL_CACHE"
    echo ""
} > "$OUTPUT_FILE"

if [[ "$DRY_RUN" = false ]]; then
    {
        echo "#!/bin/bash"
        echo "# ECR Delete Script - Generated $(date)"
        echo "# WARNING: This will permanently delete the listed images!"
        echo "# Based on CloudTrail pull data analysis"
        echo ""
        echo "set -e"
        echo ""
    } > "$DELETE_SCRIPT"
fi

# Get all repositories
REPOSITORIES=$(aws ecr describe-repositories $AWS_OPTS --query 'repositories[].repositoryName' --output text)

if [[ -z "$REPOSITORIES" ]]; then
    echo -e "${YELLOW}No ECR repositories found.${NC}"
    exit 0
fi

echo -e "${GREEN}Found repositories:${NC}"
for repo in $REPOSITORIES; do
    echo "  - $repo"
done
echo ""

# Process each repository
repo_counter=0
total_repos=$(echo "$REPOSITORIES" | wc -w)

for REPO in $REPOSITORIES; do
    repo_counter=$((repo_counter + 1))
    echo -e "${BLUE}[$repo_counter/$total_repos] Processing repository: $REPO${NC}"
    
    # Get last pull date from CloudTrail
    LAST_PULL=$(get_last_pull_date "$REPO")
    
    if [[ -n "$LAST_PULL" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            LAST_PULL_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_PULL%.*}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${LAST_PULL%T*}" +%s 2>/dev/null || echo "0")
        else
            LAST_PULL_EPOCH=$(date -d "$LAST_PULL" +%s 2>/dev/null || echo "0")
        fi
        
        LAST_PULL_FORMATTED=$(date -d "$LAST_PULL" 2>/dev/null || date -r "$LAST_PULL_EPOCH" 2>/dev/null || echo "$LAST_PULL")
        echo "  Last pull: $LAST_PULL_FORMATTED"
    else
        echo "  ${YELLOW}No pull data found in CloudTrail${NC}"
        LAST_PULL_EPOCH=0
    fi
    
    # Get all images in the repository
    echo -n "  Fetching image details... "
    IMAGES=$(aws ecr describe-images $AWS_OPTS --repository-name "$REPO" --query 'imageDetails[].{digest:imageDigest,tags:imageTags,pushed:imagePushedAt,size:imageSizeInBytes}' --output json)
    echo -e "${GREEN}✓${NC}"
    
    if [[ "$IMAGES" == "[]" ]]; then
        echo "  ${YELLOW}No images found in $REPO${NC}"
        continue
    fi
    
    # Count images in this repo
    IMAGE_COUNT=$(echo "$IMAGES" | jq length)
    TOTAL_IMAGES=$((TOTAL_IMAGES + IMAGE_COUNT))
    echo "  Found ${GREEN}$IMAGE_COUNT${NC} images"
    
    # Determine if repository is unused
    REPO_UNUSED=false
    if [[ -z "$LAST_PULL" ]]; then
        echo "  ${YELLOW}Repository has no pull data - marking all images as potentially unused${NC}"
        REPO_UNUSED=true
        NO_PULL_DATA_IMAGES=$((NO_PULL_DATA_IMAGES + IMAGE_COUNT))
    elif [[ $LAST_PULL_EPOCH -lt $CUTOFF_DATE ]]; then
        echo "  ${RED}Repository not pulled in over $CUTOFF_DAYS days - marking images as unused${NC}"
        REPO_UNUSED=true
        UNUSED_IMAGES=$((UNUSED_IMAGES + IMAGE_COUNT))
    else
        echo "  ${GREEN}Repository recently pulled - images are active${NC}"
    fi
    
    # If repository is unused, process all images
    if [[ "$REPO_UNUSED" = true ]]; then
        echo "  ${YELLOW}Processing $IMAGE_COUNT images for deletion analysis...${NC}"
        
        local processed=0
        echo "$IMAGES" | jq -r '.[] | @base64' | while IFS= read -r IMAGE_DATA; do
            processed=$((processed + 1))
            
            # Show progress every 10 images or for small batches
            if [[ $((processed % 10)) -eq 0 ]] || [[ $IMAGE_COUNT -lt 20 ]]; then
                printf "\r  Processing image %d/%d..." "$processed" "$IMAGE_COUNT"
            fi
            IMAGE_JSON=$(echo "$IMAGE_DATA" | base64 --decode)
            
            DIGEST=$(echo "$IMAGE_JSON" | jq -r '.digest')
            TAGS=$(echo "$IMAGE_JSON" | jq -r '.tags[]? // "untagged"' | tr '\n' ',' | sed 's/,$//')
            PUSHED_AT=$(echo "$IMAGE_JSON" | jq -r '.pushed')
            SIZE=$(echo "$IMAGE_JSON" | jq -r '.size // 0')
            
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
            
            # Format size
            if [[ $SIZE -gt 1073741824 ]]; then
                SIZE_FORMATTED="$(echo "scale=1; $SIZE / 1073741824" | bc 2>/dev/null || echo $(( SIZE / 1073741824 )))GB"
            elif [[ $SIZE -gt 1048576 ]]; then
                SIZE_FORMATTED="$(echo "scale=1; $SIZE / 1048576" | bc 2>/dev/null || echo $(( SIZE / 1048576 )))MB"
            elif [[ $SIZE -gt 1024 ]]; then
                SIZE_FORMATTED="$(( SIZE / 1024 ))KB"
            else
                SIZE_FORMATTED="${SIZE}B"
            fi
            
            # Create image URI
            IMAGE_URI="${REGISTRY_ID}.dkr.ecr.${CURRENT_REGION}.amazonaws.com/${REPO}@${DIGEST}"
            
            # Format pushed date
                        
            PUSHED_FORMATTED=$(date -d "$PUSHED_AT" 2>/dev/null || echo "$PUSHED_AT")
            
            # Only show detailed output for first few images to avoid spam
            if [[ $processed -le 3 ]] || [[ $IMAGE_COUNT -le 5 ]]; then
                echo ""
                echo "    UNUSED: $TAGS (pushed: $PUSHED_FORMATTED, size: $SIZE_FORMATTED)"
            fi
            
            # Write to output file
            {
                echo "Repository: $REPO"
                echo "Tags: $TAGS"
                echo "Digest: $DIGEST"
                echo "URI: $IMAGE_URI"
                echo "Pushed: $PUSHED_FORMATTED"
                echo "Last Pull: ${LAST_PULL_FORMATTED:-No pull data}"
                echo "Size: $SIZE_FORMATTED"
                echo "Status: $(if [[ -z "$LAST_PULL" ]]; then echo "No pull data"; else echo "Not pulled in $CUTOFF_DAYS+ days"; fi)"
                echo "---"
            } >> "$OUTPUT_FILE"
            
            # Add to delete script
            if [[ "$DRY_RUN" = false ]]; then
                {
                    echo "echo \"Deleting image: $REPO:$TAGS ($(if [[ -z "$LAST_PULL" ]]; then echo "no pull data"; else echo "last pulled: $LAST_PULL_FORMATTED"; fi))\""
                    echo "aws ecr batch-delete-image $AWS_OPTS --repository-name \"$REPO\" --image-ids imageDigest=\"$DIGEST\""
                    echo ""
                } >> "$DELETE_SCRIPT"
            fi
        done
        
        printf "\r  ${GREEN}✓ Processed all %d images${NC}\n" "$IMAGE_COUNT"
        
        if [[ $IMAGE_COUNT -gt 3 ]]; then
            echo "    ${YELLOW}(Showing details for first 3 images only - see report file for complete list)${NC}"
        fi
    fi
done

# Calculate totals
TOTAL_UNUSED=$((UNUSED_IMAGES + NO_PULL_DATA_IMAGES))

# Format total size
if [[ $TOTAL_SIZE -gt 1073741824 ]]; then
    TOTAL_SIZE_FORMATTED="$(echo "scale=2; $TOTAL_SIZE / 1073741824" | bc 2>/dev/null || echo $(( TOTAL_SIZE / 1073741824 )))GB"
elif [[ $TOTAL_SIZE -gt 1048576 ]]; then
    TOTAL_SIZE_FORMATTED="$(echo "scale=1; $TOTAL_SIZE / 1048576" | bc 2>/dev/null || echo $(( TOTAL_SIZE / 1048576 )))MB"
elif [[ $TOTAL_SIZE -gt 1024 ]]; then
    TOTAL_SIZE_FORMATTED="$(( TOTAL_SIZE / 1024 ))KB"
else
    TOTAL_SIZE_FORMATTED="${TOTAL_SIZE}B"
fi

echo ""
echo -e "${GREEN}=== SUMMARY ===${NC}"
echo -e "Total images scanned: ${TOTAL_IMAGES}"
echo -e "Images not pulled in $CUTOFF_DAYS+ days: ${RED}${UNUSED_IMAGES}${NC}"
echo -e "Images with no pull data: ${YELLOW}${NO_PULL_DATA_IMAGES}${NC}"
echo -e "Total potentially unused: ${RED}${TOTAL_UNUSED}${NC}"
echo -e "Total size of unused images: ${RED}${TOTAL_SIZE_FORMATTED}${NC}"
echo ""
echo -e "Detailed report saved to: ${YELLOW}$OUTPUT_FILE${NC}"

if [[ "$DRY_RUN" = false ]]; then
    if [[ $TOTAL_UNUSED -gt 0 ]]; then
        chmod +x "$DELETE_SCRIPT"
        echo -e "Delete script created: ${YELLOW}$DELETE_SCRIPT${NC}"
        echo -e "${RED}WARNING: Review the delete script carefully before running it!${NC}"
        echo -e "Run: ${YELLOW}./$DELETE_SCRIPT${NC}"
    else
        rm -f "$DELETE_SCRIPT" 2>/dev/null || true
        echo -e "${GREEN}No unused images found - no delete script created.${NC}"
    fi
else
    echo -e "${BLUE}Dry run complete - no delete script created.${NC}"
fi

if [[ $TOTAL_UNUSED -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Potential cost savings by cleaning up unused images:${NC}"
    echo -e "Storage: ~\$$(echo "scale=2; $TOTAL_SIZE / 1073741824 * 0.10" | bc 2>/dev/null || echo "N/A")/month"
fi

if [[ $NO_PULL_DATA_IMAGES -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Note: $NO_PULL_DATA_IMAGES images have no CloudTrail pull data.${NC}"
    echo "This could mean:"
    echo "- Images were never pulled"
    echo "- CloudTrail logging wasn't enabled when they were pulled"
    echo "- Pull events are outside the search timeframe"
    echo "Consider investigating these manually before deletion."
fi

echo ""
echo -e "${BLUE}CloudTrail cache saved to: $CLOUDTRAIL_CACHE${NC}"
echo "Reuse with --cache-only for faster subsequent runs."#!/bin/bash

# ECR Unused Images Cleanup Script with CloudTrail Integration
# Identifies ECR images that haven't been pulled in over 6 months using actual pull data
# Usage: ./ecr-cleanup.sh [--dry-run] [--region us-east-1] [--registry-id 123456789012]

set -e

# Default values
DRY_RUN=false
REGION=""
REGISTRY_ID=""
CUTOFF_DAYS=180  # 6 months
OUTPUT_FILE="ecr-unused-images-$(date +%Y%m%d-%H%M%S).txt"
DELETE_SCRIPT="ecr-delete-unused-$(date +%Y%m%d-%H%M%S).sh"
CLOUDTRAIL_CACHE="cloudtrail-cache-$(date +%Y%m%d).json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --dry-run              Only identify unused images, don't create delete script"
    echo "  --region REGION        AWS region (default: uses AWS CLI default)"
    echo "  --registry-id ID       ECR registry ID (default: uses current account)"
    echo "  --days DAYS            Days threshold for unused images (default: 180)"
    echo "  --cache-only           Use existing CloudTrail cache file only"
    echo "  --no-cache             Skip cache, always fetch fresh CloudTrail data"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run"
    echo "  $0 --region us-west-2 --days 90"
    echo "  $0 --registry-id 123456789012"
    echo ""
    echo "Note: This script requires CloudTrail to be enabled with ECR API logging."
    echo "It looks for BatchGetImage and GetDownloadUrlForLayer events to determine actual pull dates."
}

# Parse command line arguments
CACHE_ONLY=false
NO_CACHE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --registry-id)
            REGISTRY_ID="$2"
            shift 2
            ;;
        --days)
            CUTOFF_DAYS="$2"
            shift 2
            ;;
        --cache-only)
            CACHE_ONLY=true
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Build AWS CLI command options
AWS_OPTS=""
if [[ -n "$REGION" ]]; then
    AWS_OPTS="$AWS_OPTS --region $REGION"
    CURRENT_REGION="$REGION"
else
    CURRENT_REGION=$(aws configure get region)
fi

if [[ -n "$REGISTRY_ID" ]]; then
    AWS_OPTS="$AWS_OPTS --registry-id $REGISTRY_ID"
fi

# Calculate cutoff date
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    CUTOFF_DATE=$(date -v-${CUTOFF_DAYS}d +%s)
    CUTOFF_ISO=$(date -v-${CUTOFF_DAYS}d -u +"%Y-%m-%dT%H:%M:%SZ")
else
    # Linux
    CUTOFF_DATE=$(date -d "${CUTOFF_DAYS} days ago" +%s)
    CUTOFF_ISO=$(date -d "${CUTOFF_DAYS} days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
fi

echo -e "${BLUE}ECR Unused Images Cleanup Script (CloudTrail Integration)${NC}"
echo -e "Cutoff: ${CUTOFF_DAYS} days ($(date -d "@$CUTOFF_DATE" 2>/dev/null || date -r "$CUTOFF_DATE"))"
echo -e "Region: ${CURRENT_REGION}"
echo -e "Registry ID: ${REGISTRY_ID:-current account}"
echo ""

# Check dependencies
for cmd in aws jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}Error: $cmd not found. Please install $cmd first.${NC}"
        exit 1
    fi
done

# Check AWS credentials
if ! aws sts get-caller-identity $AWS_OPTS &> /dev/null; then
    echo -e "${RED}Error: AWS credentials not configured or invalid.${NC}"
    exit 1
fi

# Get current account ID if not provided
if [[ -z "$REGISTRY_ID" ]]; then
    REGISTRY_ID=$(aws sts get-caller-identity $AWS_OPTS --query 'Account' --output text)
fi

# Function to show spinning progress indicator
show_progress() {
    local pid=$1
    local message="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %10 ))
        printf "\r${YELLOW}%s %c${NC}" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r%s... ${GREEN}Done${NC}\n" "$message"
}

# Function to fetch CloudTrail events with progress tracking
fetch_cloudtrail_events() {
    echo -e "${YELLOW}Fetching CloudTrail events for ECR pulls...${NC}"
    echo "This may take several minutes depending on the volume of events."
    
    local temp_file=$(mktemp)
    local start_time="$CUTOFF_ISO"
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    echo "Searching CloudTrail from $start_time to $end_time"
    echo ""
    
    # Try CloudWatch Logs first
    echo -e "${BLUE}Step 1/3: Attempting CloudWatch Logs query...${NC}"
    
    (aws logs start-query $AWS_OPTS \
        --log-group-name "CloudTrail/ECREvents" \
        --start-time $(date -d "$start_time" +%s) \
        --end-time $(date -d "$end_time" +%s) \
        --query-string 'fields @timestamp, eventName, sourceIPAddress, userIdentity.type, requestParameters, responseElements
        | filter eventName in ["BatchGetImage", "GetDownloadUrlForLayer"]
        | filter requestParameters.repositoryName exists
        | sort @timestamp desc' > /dev/null 2>&1) &
    
    local logs_pid=$!
    show_progress $logs_pid "Querying CloudWatch Logs"
    
    if wait $logs_pid; then
        echo -e "${GREEN}CloudWatch Logs query successful${NC}"
    else
        echo -e "${YELLOW}CloudWatch Logs not available, falling back to CloudTrail API...${NC}"
        echo ""
        
        # Fallback to CloudTrail API with progress tracking
        echo -e "${BLUE}Step 2/3: Fetching BatchGetImage events...${NC}"
        
        (aws cloudtrail lookup-events $AWS_OPTS \
            --lookup-attributes AttributeKey=EventName,AttributeValue=BatchGetImage \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --query 'Events[].{Time:EventTime,EventName:EventName,Resources:Resources,CloudTrailEvent:CloudTrailEvent}' \
            --output json > "${temp_file}.batch") &
        
        local batch_pid=$!
        show_progress $batch_pid "Fetching BatchGetImage events"
        wait $batch_pid
        
        local batch_count=$(jq length "${temp_file}.batch" 2>/dev/null || echo "0")
        echo -e "  Found ${GREEN}$batch_count${NC} BatchGetImage events"
        
        echo -e "${BLUE}Step 3/3: Fetching GetDownloadUrlForLayer events...${NC}"
        
        (aws cloudtrail lookup-events $AWS_OPTS \
            --lookup-attributes AttributeKey=EventName,AttributeValue=GetDownloadUrlForLayer \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --query 'Events[].{Time:EventTime,EventName:EventName,Resources:Resources,CloudTrailEvent:CloudTrailEvent}' \
            --output json > "${temp_file}.download") &
        
        local download_pid=$!
        show_progress $download_pid "Fetching GetDownloadUrlForLayer events"
        wait $download_pid
        
        local download_count=$(jq length "${temp_file}.download" 2>/dev/null || echo "0")
        echo -e "  Found ${GREEN}$download_count${NC} GetDownloadUrlForLayer events"
        
        echo -e "${BLUE}Combining and processing events...${NC}"
        
        # Combine and process events with progress
        (jq -s 'add | map(select(.CloudTrailEvent != null) | .CloudTrailEvent = (.CloudTrailEvent | fromjson))' \
            "${temp_file}.batch" "${temp_file}.download" > "$temp_file") &
        
        local combine_pid=$!
        show_progress $combine_pid "Processing CloudTrail data"
        wait $combine_pid
        
        rm -f "${temp_file}.batch" "${temp_file}.download"
        
        local total_events=$(jq length "$temp_file" 2>/dev/null || echo "0")
        echo -e "  Total events to process: ${GREEN}$total_events${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Processing CloudTrail data into cache format...${NC}"
    
    # Process and cache the events with progress indication
    if [[ -s "$temp_file" ]]; then
        echo -n "Analyzing events and grouping by repository... "
        
        # Extract relevant information and create cache format
        (jq -r '
        map(select(.CloudTrailEvent.requestParameters.repositoryName != null)) |
        map({
            timestamp: (.Time // .CloudTrailEvent.eventTime),
            repository: .CloudTrailEvent.requestParameters.repositoryName,
            imageId: (.CloudTrailEvent.requestParameters.imageIds[0] // {}),
            registryId: (.CloudTrailEvent.requestParameters.registryId // ""),
            sourceIP: (.CloudTrailEvent.sourceIPAddress // ""),
            userType: (.CloudTrailEvent.userIdentity.type // "")
        }) |
        group_by(.repository) |
        map({
            repository: .[0].repository,
            lastPull: (map(.timestamp) | max),
            pullCount: length,
            registryId: .[0].registryId
        })
        ' "$temp_file" > "$CLOUDTRAIL_CACHE") &
        
        local process_pid=$!
        show_progress $process_pid "Creating repository cache"
        wait $process_pid
        
        rm -f "$temp_file"
        
        # Show summary of cached data
        local repo_count=$(jq length "$CLOUDTRAIL_CACHE" 2>/dev/null || echo "0")
        local total_pulls=$(jq '[.[].pullCount] | add' "$CLOUDTRAIL_CACHE" 2>/dev/null || echo "0")
        
        echo -e "${GREEN}✓ CloudTrail analysis complete${NC}"
        echo -e "  Repositories with pull data: ${GREEN}$repo_count${NC}"
        echo -e "  Total pull events processed: ${GREEN}$total_pulls${NC}"
        echo -e "  Cache saved to: ${YELLOW}$CLOUDTRAIL_CACHE${NC}"
    else
        echo -e "${RED}✗ No CloudTrail events found${NC}"
        echo -e "${RED}Ensure CloudTrail is enabled for ECR API calls.${NC}"
        echo ""
        echo "To enable CloudTrail for ECR:"
        echo "1. Go to CloudTrail console"
        echo "2. Create or edit a trail"
        echo "3. Ensure 'Data events' are enabled for ECR"
        echo "4. Wait for events to accumulate (may take time)"
        exit 1
    fi
}

# Function to get last pull date for a repository
get_last_pull_date() {
    local repo="$1"
    local last_pull=""
    
    if [[ -f "$CLOUDTRAIL_CACHE" ]]; then
        last_pull=$(jq -r --arg repo "$repo" '.[] | select(.repository == $repo) | .lastPull // empty' "$CLOUDTRAIL_CACHE")
    fi
    
    echo "$last_pull"
}

# Handle CloudTrail data fetching
if [[ "$CACHE_ONLY" = true ]]; then
    if [[ ! -f "$CLOUDTRAIL_CACHE" ]]; then
        echo -e "${RED}Error: Cache file $CLOUDTRAIL_CACHE not found. Run without --cache-only first.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Using cached CloudTrail data: $CLOUDTRAIL_CACHE${NC}"
elif [[ "$NO_CACHE" = true ]] || [[ ! -f "$CLOUDTRAIL_CACHE" ]]; then
    fetch_cloudtrail_events
else
    echo -e "${YELLOW}Using existing CloudTrail cache: $CLOUDTRAIL_CACHE${NC}"
    echo "Use --no-cache to fetch fresh data or --cache-only to ensure using cache only"
fi

echo -e "${YELLOW}Scanning ECR repositories...${NC}"

# Initialize counters
TOTAL_IMAGES=0
UNUSED_IMAGES=0
NO_PULL_DATA_IMAGES=0
TOTAL_SIZE=0

# Create output files
{
    echo "# ECR Unused Images Report - $(date)"
    echo "# Images not pulled in over $CUTOFF_DAYS days (based on CloudTrail data)"
    echo "# Registry: $REGISTRY_ID, Region: $CURRENT_REGION"
    echo "# CloudTrail cache: $CLOUDTRAIL_CACHE"
    echo ""
} > "$OUTPUT_FILE"

if [[ "$DRY_RUN" = false ]]; then
    {
        echo "#!/bin/bash"
        echo "# ECR Delete Script - Generated $(date)"
        echo "# WARNING: This will permanently delete the listed images!"
        echo "# Based on CloudTrail pull data analysis"
        echo ""
        echo "set -e"
        echo ""
    } > "$DELETE_SCRIPT"
fi

# Get all repositories
REPOSITORIES=$(aws ecr describe-repositories $AWS_OPTS --query 'repositories[].repositoryName' --output text)

if [[ -z "$REPOSITORIES" ]]; then
    echo -e "${YELLOW}No ECR repositories found.${NC}"
    exit 0
fi

echo -e "${GREEN}Found repositories:${NC}"
for repo in $REPOSITORIES; do
    echo "  - $repo"
done
echo ""

# Process each repository
repo_counter=0
total_repos=$(echo "$REPOSITORIES" | wc -w)

for REPO in $REPOSITORIES; do
    repo_counter=$((repo_counter + 1))
    echo -e "${BLUE}[$repo_counter/$total_repos] Processing repository: $REPO${NC}"
    
    # Get last pull date from CloudTrail
    LAST_PULL=$(get_last_pull_date "$REPO")
    
    if [[ -n "$LAST_PULL" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            LAST_PULL_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${LAST_PULL%.*}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${LAST_PULL%T*}" +%s 2>/dev/null || echo "0")
        else
            LAST_PULL_EPOCH=$(date -d "$LAST_PULL" +%s 2>/dev/null || echo "0")
        fi
        
        LAST_PULL_FORMATTED=$(date -d "$LAST_PULL" 2>/dev/null || date -r "$LAST_PULL_EPOCH" 2>/dev/null || echo "$LAST_PULL")
        echo "  Last pull: $LAST_PULL_FORMATTED"
    else
        echo "  ${YELLOW}No pull data found in CloudTrail${NC}"
        LAST_PULL_EPOCH=0
    fi
    
    # Get all images in the repository
    echo -n "  Fetching image details... "
    IMAGES=$(aws ecr describe-images $AWS_OPTS --repository-name "$REPO" --query 'imageDetails[].{digest:imageDigest,tags:imageTags,pushed:imagePushedAt,size:imageSizeInBytes}' --output json)
    echo -e "${GREEN}✓${NC}"
    
    if [[ "$IMAGES" == "[]" ]]; then
        echo "  ${YELLOW}No images found in $REPO${NC}"
        continue
    fi
    
    # Count images in this repo
    IMAGE_COUNT=$(echo "$IMAGES" | jq length)
    TOTAL_IMAGES=$((TOTAL_IMAGES + IMAGE_COUNT))
    echo "  Found ${GREEN}$IMAGE_COUNT${NC} images"
    
    # Determine if repository is unused
    REPO_UNUSED=false
    if [[ -z "$LAST_PULL" ]]; then
        echo "  ${YELLOW}Repository has no pull data - marking all images as potentially unused${NC}"
        REPO_UNUSED=true
        NO_PULL_DATA_IMAGES=$((NO_PULL_DATA_IMAGES + IMAGE_COUNT))
    elif [[ $LAST_PULL_EPOCH -lt $CUTOFF_DATE ]]; then
        echo "  ${RED}Repository not pulled in over $CUTOFF_DAYS days - marking images as unused${NC}"
        REPO_UNUSED=true
        UNUSED_IMAGES=$((UNUSED_IMAGES + IMAGE_COUNT))
    else
        echo "  ${GREEN}Repository recently pulled - images are active${NC}"
    fi
    
    # If repository is unused, process all images
    if [[ "$REPO_UNUSED" = true ]]; then
        echo "  ${YELLOW}Processing $IMAGE_COUNT images for deletion analysis...${NC}"
        
        local processed=0
        echo "$IMAGES" | jq -r '.[] | @base64' | while IFS= read -r IMAGE_DATA; do
            processed=$((processed + 1))
            
            # Show progress every 10 images or for small batches
            if [[ $((processed % 10)) -eq 0 ]] || [[ $IMAGE_COUNT -lt 20 ]]; then
                printf "\r  Processing image %d/%d..." "$processed" "$IMAGE_COUNT"
            fi
            IMAGE_JSON=$(echo "$IMAGE_DATA" | base64 --decode)
            
            DIGEST=$(echo "$IMAGE_JSON" | jq -r '.digest')
            TAGS=$(echo "$IMAGE_JSON" | jq -r '.tags[]? // "untagged"' | tr '\n' ',' | sed 's/,$//')
            PUSHED_AT=$(echo "$IMAGE_JSON" | jq -r '.pushed')
            SIZE=$(echo "$IMAGE_JSON" | jq -r '.size // 0')
            
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
            
            # Format size
            if [[ $SIZE -gt 1073741824 ]]; then
                SIZE_FORMATTED="$(echo "scale=1; $SIZE / 1073741824" | bc 2>/dev/null || echo $(( SIZE / 1073741824 )))GB"
            elif [[ $SIZE -gt 1048576 ]]; then
                SIZE_FORMATTED="$(echo "scale=1; $SIZE / 1048576" | bc 2>/dev/null || echo $(( SIZE / 1048576 )))MB"
            elif [[ $SIZE -gt 1024 ]]; then
                SIZE_FORMATTED="$(( SIZE / 1024 ))KB"
            else
                SIZE_FORMATTED="${SIZE}B"
            fi
            
            # Create image URI
            IMAGE_URI="${REGISTRY_ID}.dkr.ecr.${CURRENT_REGION}.amazonaws.com/${REPO}@${DIGEST}"
            
            # Format pushed date
                        
            PUSHED_FORMATTED=$(date -d "$PUSHED_AT" 2>/dev/null || echo "$PUSHED_AT")
            
            # Only show detailed output for first few images to avoid spam
            if [[ $processed -le 3 ]] || [[ $IMAGE_COUNT -le 5 ]]; then
                echo ""
                echo "    UNUSED: $TAGS (pushed: $PUSHED_FORMATTED, size: $SIZE_FORMATTED)"
            fi
            
            # Write to output file
            {
                echo "Repository: $REPO"
                echo "Tags: $TAGS"
                echo "Digest: $DIGEST"
                echo "URI: $IMAGE_URI"
                echo "Pushed: $PUSHED_FORMATTED"
                echo "Last Pull: ${LAST_PULL_FORMATTED:-No pull data}"
                echo "Size: $SIZE_FORMATTED"
                echo "Status: $(if [[ -z "$LAST_PULL" ]]; then echo "No pull data"; else echo "Not pulled in $CUTOFF_DAYS+ days"; fi)"
                echo "---"
            } >> "$OUTPUT_FILE"
            
            # Add to delete script
            if [[ "$DRY_RUN" = false ]]; then
                {
                    echo "echo \"Deleting image: $REPO:$TAGS ($(if [[ -z "$LAST_PULL" ]]; then echo "no pull data"; else echo "last pulled: $LAST_PULL_FORMATTED"; fi))\""
                    echo "aws ecr batch-delete-image $AWS_OPTS --repository-name \"$REPO\" --image-ids imageDigest=\"$DIGEST\""
                    echo ""
                } >> "$DELETE_SCRIPT"
            fi
        done
        
        printf "\r  ${GREEN}✓ Processed all %d images${NC}\n" "$IMAGE_COUNT"
        
        if [[ $IMAGE_COUNT -gt 3 ]]; then
            echo "    ${YELLOW}(Showing details for first 3 images only - see report file for complete list)${NC}"
        fi
    fi
done

# Calculate totals
TOTAL_UNUSED=$((UNUSED_IMAGES + NO_PULL_DATA_IMAGES))

# Format total size
if [[ $TOTAL_SIZE -gt 1073741824 ]]; then
    TOTAL_SIZE_FORMATTED="$(echo "scale=2; $TOTAL_SIZE / 1073741824" | bc 2>/dev/null || echo $(( TOTAL_SIZE / 1073741824 )))GB"
elif [[ $TOTAL_SIZE -gt 1048576 ]]; then
    TOTAL_SIZE_FORMATTED="$(echo "scale=1; $TOTAL_SIZE / 1048576" | bc 2>/dev/null || echo $(( TOTAL_SIZE / 1048576 )))MB"
elif [[ $TOTAL_SIZE -gt 1024 ]]; then
    TOTAL_SIZE_FORMATTED="$(( TOTAL_SIZE / 1024 ))KB"
else
    TOTAL_SIZE_FORMATTED="${TOTAL_SIZE}B"
fi

echo ""
echo -e "${GREEN}=== SUMMARY ===${NC}"
echo -e "Total images scanned: ${TOTAL_IMAGES}"
echo -e "Images not pulled in $CUTOFF_DAYS+ days: ${RED}${UNUSED_IMAGES}${NC}"
echo -e "Images with no pull data: ${YELLOW}${NO_PULL_DATA_IMAGES}${NC}"
echo -e "Total potentially unused: ${RED}${TOTAL_UNUSED}${NC}"
echo -e "Total size of unused images: ${RED}${TOTAL_SIZE_FORMATTED}${NC}"
echo ""
echo -e "Detailed report saved to: ${YELLOW}$OUTPUT_FILE${NC}"

if [[ "$DRY_RUN" = false ]]; then
    if [[ $TOTAL_UNUSED -gt 0 ]]; then
        chmod +x "$DELETE_SCRIPT"
        echo -e "Delete script created: ${YELLOW}$DELETE_SCRIPT${NC}"
        echo -e "${RED}WARNING: Review the delete script carefully before running it!${NC}"
        echo -e "Run: ${YELLOW}./$DELETE_SCRIPT${NC}"
    else
        rm -f "$DELETE_SCRIPT" 2>/dev/null || true
        echo -e "${GREEN}No unused images found - no delete script created.${NC}"
    fi
else
    echo -e "${BLUE}Dry run complete - no delete script created.${NC}"
fi

if [[ $TOTAL_UNUSED -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Potential cost savings by cleaning up unused images:${NC}"
    echo -e "Storage: ~\$$(echo "scale=2; $TOTAL_SIZE / 1073741824 * 0.10" | bc 2>/dev/null || echo "N/A")/month"
fi

if [[ $NO_PULL_DATA_IMAGES -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Note: $NO_PULL_DATA_IMAGES images have no CloudTrail pull data.${NC}"
    echo "This could mean:"
    echo "- Images were never pulled"
    echo "- CloudTrail logging wasn't enabled when they were pulled"
    echo "- Pull events are outside the search timeframe"
    echo "Consider investigating these manually before deletion."
fi

echo ""
echo -e "${BLUE}CloudTrail cache saved to: $CLOUDTRAIL_CACHE${NC}"
echo "Reuse with --cache-only for faster subsequent runs."