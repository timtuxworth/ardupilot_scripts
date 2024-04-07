# arming_checks

This script implements user defined pre-arm and arming checks. Checks
can be warnings or errors. Warnings don't prevent arming but will display
on the ground station, whereas errors will prevent arming.

# Parameters

# NO PARAMETERS 

This ...

# Operation

Copy this file to the APM/scripts folder on your SD card and make sure 

SCR_ENABLE = 1
SCR_HEAPSIZE = 250000 (minimum)
SCR_VM_. = 200000 (minimum)

Edit the arming_checks table if you want to change any of the checks from warnings to errors or errors to warnings or delete the row if you want to remove the check completely.

You can add your own checks by definition a function that makes the check and add it to the
table.