#!/bin/bash

################################################################################
# Docker Total Cleanup Script
# 
# ⚠️  WARNING: This script will DELETE EVERYTHING from Docker!
# - All containers (running and stopped)
# - All images (used and unused)
# - All volumes (mounted and unmounted)
# - All networks (except default bridge)
# - All build cache
# - All dangling data
#
# USE WITH CAUTION! This cannot be undone!
################################################################################

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${RED}"
    echo "========================================"
    echo "   Docker TOTAL Cleanup Script"
    echo "========================================"
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

show_current_usage() {
    echo ""
    print_info "Current Docker disk usage:"
    docker system df
    echo ""
}

confirm_cleanup() {
    echo -e "${RED}"
    echo "⚠️  WARNING: This will DELETE EVERYTHING from Docker!"
    echo ""
    echo "What will be removed:"
    echo "  • All containers (running and stopped)"
    echo "  • All images (including base images)"
    echo "  • All volumes (all data will be lost)"
    echo "  • All networks (except default)"
    echo "  • All build cache"
    echo ""
    echo "This action CANNOT be undone!"
    echo -e "${NC}"
    
    read -p "Type 'YES' in capital letters to confirm: " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        print_warning "Cleanup cancelled by user"
        exit 0
    fi
    
    echo ""
    print_warning "Last chance! Starting cleanup in 5 seconds..."
    print_warning "Press Ctrl+C to cancel"
    sleep 5
}

stop_all_containers() {
    print_info "Step 1/7: Stopping all running containers..."
    
    RUNNING=$(docker ps -q)
    if [ -n "$RUNNING" ]; then
        docker stop $(docker ps -q) 2>/dev/null || true
        print_success "All containers stopped"
    else
        print_info "No running containers"
    fi
    echo ""
}

remove_all_containers() {
    print_info "Step 2/7: Removing all containers..."
    
    CONTAINERS=$(docker ps -aq)
    if [ -n "$CONTAINERS" ]; then
        docker rm -f $(docker ps -aq) 2>/dev/null || true
        print_success "All containers removed"
    else
        print_info "No containers to remove"
    fi
    echo ""
}

remove_all_images() {
    print_info "Step 3/7: Removing all images..."
    
    IMAGES=$(docker images -q)
    if [ -n "$IMAGES" ]; then
        docker rmi -f $(docker images -q) 2>/dev/null || true
        print_success "All images removed"
    else
        print_info "No images to remove"
    fi
    echo ""
}

remove_all_volumes() {
    print_info "Step 4/7: Removing all volumes..."
    
    VOLUMES=$(docker volume ls -q)
    if [ -n "$VOLUMES" ]; then
        docker volume rm $(docker volume ls -q) 2>/dev/null || true
        print_success "All volumes removed"
    else
        print_info "No volumes to remove"
    fi
    echo ""
}

remove_all_networks() {
    print_info "Step 5/7: Removing all custom networks..."
    
    # Get all networks except bridge, host, and none
    NETWORKS=$(docker network ls --filter type=custom -q)
    if [ -n "$NETWORKS" ]; then
        docker network rm $(docker network ls --filter type=custom -q) 2>/dev/null || true
        print_success "All custom networks removed"
    else
        print_info "No custom networks to remove"
    fi
    echo ""
}

remove_build_cache() {
    print_info "Step 6/7: Removing all build cache..."
    
    docker builder prune -af 2>/dev/null || true
    print_success "Build cache removed"
    echo ""
}

final_prune() {
    print_info "Step 7/7: Final system prune (remove all unused data)..."
    
    docker system prune -af --volumes 2>/dev/null || true
    print_success "Final prune completed"
    echo ""
}

show_final_usage() {
    echo ""
    print_success "Cleanup completed!"
    echo ""
    print_info "Final Docker disk usage:"
    docker system df
    echo ""
}

################################################################################
# Main Script
################################################################################

print_header

# Check if Docker is running
if ! docker ps &> /dev/null; then
    print_warning "Docker is not running!"
    exit 1
fi

# Show current usage
show_current_usage

# Confirm with user
confirm_cleanup

# Execute cleanup steps
stop_all_containers
remove_all_containers
remove_all_images
remove_all_volumes
remove_all_networks
remove_build_cache
final_prune

# Show final usage
show_final_usage

echo -e "${GREEN}"
echo "========================================"
echo "   Docker is now COMPLETELY CLEAN!"
echo "========================================"
echo -e "${NC}"
echo ""
print_info "Docker has been reset to a fresh state"
print_info "You can now rebuild your projects from scratch"
echo ""
