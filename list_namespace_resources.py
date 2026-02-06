#!/usr/bin/env python3
"""
List all resources in a Kubernetes namespace.

Usage:
    python list_namespace_resources.py <namespace> [--json]
"""

import subprocess
import sys
import json
from datetime import datetime, timezone


def run_kubectl(args):
    """Run kubectl command and return output."""
    cmd = ["kubectl"] + args
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout, result.stderr


def get_age(creation_timestamp):
    """Calculate age from timestamp."""
    if not creation_timestamp:
        return "N/A"

    try:
        created_at = datetime.fromisoformat(creation_timestamp.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        delta = now - created_at

        days = delta.days
        seconds = delta.seconds

        if days > 0:
            return f"{days}d"
        elif seconds > 3600:
            return f"{seconds // 3600}h"
        elif seconds > 60:
            return f"{seconds // 60}m"
        else:
            return f"{seconds}s"
    except ValueError:
        return "N/A"


def get_status(item, resource_type):
    """Extract status from different resource types."""
    status_field = item.get("status", {})

    if "phase" in status_field:
        return status_field["phase"]
    elif "readyReplicas" in status_field:
        ready = status_field.get("readyReplicas", 0)
        replicas = status_field.get("replicas", 0)
        return f"{ready}/{replicas}"
    elif "conditions" in status_field:
        for cond in status_field["conditions"]:
            if cond.get("type") == "Ready":
                return cond.get("status", "Unknown")
    return "N/A"


def get_all_resources_in_namespace(namespace):
    """Get all resources in the specified namespace."""
    resources = []

    stdout, _ = run_kubectl(["api-resources", "--namespaced=true", "--verbs=list", "-o", "name"])
    resource_types = stdout.strip().split("\n")

    omit_types = {"events", "events.events.k8s.io"}

    for resource_type in resource_types:
        if not resource_type or resource_type in omit_types:
            continue

        stdout, stderr = run_kubectl([
            "get", resource_type,
            "-n", namespace,
            "-o", "json"
        ])

        if stderr and "not found" in stderr.lower():
            continue

        try:
            data = json.loads(stdout)
            items = data.get("items", [])
            for item in items:
                resources.append({
                    "type": resource_type,
                    "name": item.get("metadata", {}).get("name", "unknown"),
                    "namespace": item.get("metadata", {}).get("namespace", namespace),
                    "status": get_status(item, resource_type),
                    "age": get_age(item.get("metadata", {}).get("creationTimestamp", "")),
                })
        except json.JSONDecodeError:
            continue

    return resources


def format_resource(resource):
    """Format a single resource as a one-line string."""
    return f"{resource['type']:<40} {resource['name']:<50} {resource['status']:<15} {resource['age']}"


def main():
    json_output = "--json" in sys.argv
    args = [arg for arg in sys.argv[1:] if arg != "--json"]

    if len(args) != 1:
        print(f"Usage: {sys.argv[0]} <namespace> [--json]")
        sys.exit(1)

    namespace = args[0]
    resources = get_all_resources_in_namespace(namespace)

    if json_output:
        print(json.dumps(resources, indent=2))
    else:
        print(f"Resources in namespace: {namespace}")
        print("=" * 120)
        print(f"{'TYPE':<40} {'NAME':<50} {'STATUS':<15} {'AGE'}")
        print("-" * 120)

        for resource in sorted(resources, key=lambda x: (x["type"], x["name"])):
            print(format_resource(resource))

        print("-" * 120)
        print(f"Total: {len(resources)} resources")


if __name__ == "__main__":
    main()
