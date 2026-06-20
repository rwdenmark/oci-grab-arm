# Template for oci_grab_arm.ps1 personal values.
# Copy this file to "oci_grab_arm.config.ps1" and fill in your own OCIDs.
# The real config file is gitignored so your values never get committed.
#
# Where to find these:
#   COMPARTMENT_ID - your tenancy OCID: Console -> Profile -> Tenancy (or use the root compartment).
#   SUBNET_ID      - Console -> Networking -> Virtual Cloud Networks -> <your VCN> -> Subnets -> Subnet details.

$COMPARTMENT_ID = "ocid1.tenancy.oc1..REPLACE_WITH_YOUR_TENANCY_OCID"
$SUBNET_ID      = "ocid1.subnet.oc1.<region>.REPLACE_WITH_YOUR_SUBNET_OCID"
