# Functions can be scheduled through OCI Resource Scheduler. The provider's
# generic schedule schema does not yet expose the Functions-console workflow
# cleanly, so create the schedule in the OCI Functions console after Terraform
# has created the function. The README gives the exact steps, required scheduler
# dynamic group, and the least-privilege invoke policy.
