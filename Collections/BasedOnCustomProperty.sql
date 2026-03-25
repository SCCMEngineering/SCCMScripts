-- https://learn.microsoft.com/en-us/intune/configmgr/develop/adminservice/custom-properties
SELECT 
    SMS_R_SYSTEM.ResourceID,SMS_R_SYSTEM.ResourceType,SMS_R_SYSTEM.Name,SMS_R_SYSTEM.SMSUniqueIdentifier,SMS_R_SYSTEM.ResourceDomainORWorkgroup,SMS_R_SYSTEM.Client
FROM 
    SMS_R_System inner join SMS_G_System_ExtensionData on SMS_G_System_ExtensionData.ResourceId = SMS_R_System.ResourceId
WHERE 
    SMS_G_System_ExtensionData.PropertyName = "YOURCUSTOMPROPERTY" 
    AND SMS_G_System_ExtensionData.PropertyValue = "EXPECTEDVALUE"

