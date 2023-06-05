# Azure-WI-Parent-Updater
A pipeline to update parent items from a "Proposed" state to an "InProgress" state.  This functionality is process and state name agnostic, retrieving these fields from your project at runtime.

How to use:

**Set up an incoming WebHook:**
1. Go to Project Settings / Service Connections
2. Click New Service Connection
3. Select Incoming Webhook

![image](https://github.com/Big-Bald-Mike/ADO-WI-Parent-Updater/assets/7321330/9fe123dc-640e-4a5d-89d8-ef617e2ce8d1)

4. Give it a webHook name and a service connection name.
    (I made these the same because the documentation is unclear about which one is called by the pipeline as a resource)
5. Remember the webhook name.  You will need it in future steps.

**Set up an outgoing WebHook:**
1. Go to Project Settings / Service Hooks, and click the green plus symbol.

![image](https://github.com/Big-Bald-Mike/ADO-WI-Parent-Updater/assets/7321330/07492da4-a791-429e-90d9-559c39a6aefb)

2. Select Web Hooks and click Next.

![image](https://github.com/Big-Bald-Mike/ADO-WI-Parent-Updater/assets/7321330/7920b2d0-18c6-451c-b472-d215d87f0a7f)

3. Trigger on this type of event:  Work item updated
4. Work item type: Task  (I suggest that if you want to do it for other work item types such as User Stories or Features, you make separate webhooks for those.)
5. Click Next
6. URL is in this format:

https://dev.azure.com/{ YOUR PROJECT HERE }/\_apis/public/distributedtask/webhooks/{ YOUR WEBHOOK NAME }/?api-version=6.0-preview

7. Test and Finish.

**Create a Personal Access Token**
1. Create a Personal Access Token with the "Read, Write, and Manage" permission.

![image](https://github.com/Big-Bald-Mike/ADO-WI-Parent-Updater/assets/7321330/95970f09-a530-4866-b10d-15366229e9c7)

2. Save the token for use in the next step.

**Set up your repo and pipeline**

I'm not going to write out the process for setting up a pipeline here.  It should be known to someone setting up ADO webhooks.
1. Copy the 'ADO Pipelines' folder (with the Scripts subfolder) into a new or existin toolbox repo.  
2. Feel free to adjust paths as is convenient for your setup.
3. In your new pipeline, Click Edit, then click Variables
4. Create a variable called "token" and enter your new PAT for the value.  Mark it as secret.
5. Create a variable called "org" and enter your organization name.
6. Create a variable called "project" and enter your project name.

(I am working on making this project and org agnostic but ADO has triggering issues if you try to read certain endpoints in the incoming JSON.)

**See if it works**

1. Set up a task under a parent in your project, both in their initial state.
2. Move your task to your first "In Progress" column.
3. The pipeline may ask for permission to your service connection the first time it runs.  Provide that.

