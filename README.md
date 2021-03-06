JeCloud
=======

**Early stage project, beware! — see ‘Roadmap & status of 0.1’ below**

It's mingboggingly retarded that every startup owner has to build his own cloud stack from scratch, unless he is satisfied with existing hosted solutions like Heroku.

After living on Google App Engine for a while and becoming increasingly sick with its inadequate progress, monthly downtimes, timeouts and datastore limitations (which were fine a couple years earlier, but don't look so cool now compared to Mongo/Couch/etc), and lack of node.js support, I finally had too much.  Fuck you, Google.  I decided that I want to stop working on my startup (however unfortunate that may be) and build an open-source stack, once and for all.

JeCloud is (will be some day) an all-inclusive open-source cloud stack, similar to Google App Engine and Heroku. It will provide Node.js, Rails, MongoDB and Redis (and probably some other services) out of the box, together with automatic scaling and health monitoring.

JeCloud will initially run on EC2, with more cloud providers (Rackspace Cloud, Linode, Joyent)
supported in the future as time permits (contributions welcome).

My goal is to build something really simple that works for me — I need to get back to my startup soon, after all.


Running JeCloud
---------------

The following scenario should work for you:

* copy `example/cloud-access.yml.example` into `example/cloud-access.yml` and insert your AWS access keys
* make sure you are signed up for both EC2 and S3 (go to http://aws.amazon.com/ and click ‘Sign in to the AWS Management Console’)
* run `bundle install` to install all prerequisite gems
* run `rake install` to install the gem (or `rake link` to install stubs for development — `jecloud` stub will invoke `bin/jecloud` right from the development directory)
* cd into `example`
* run `jecloud apply cloud.yml` — you should see a new EC2 server instance created and set up (required yum packages installed, then JeCloud gem installed)

Invoke `jecloud --help` to see a list of all available commands.

JeCloud already does:

* create a new EC2 key pair (required for SSH access to the servers)
* create and set up a EC2 server
* install and update JeCloud gem on the server

JeCloud does **NOT** yet:

* upload your application source code to the server (this is be the next step)
* set up or run actual node.js / mongodb / whatever


JeCloud concepts
----------------

* There is a global *cloud state* stored on Amazon S3. Currently it includes a list of servers in use (IP, EC2 instance ID for each server), a list of recently failed actions (for backing off), the last deployment request, SSH keys for the cloud servers and for the source Git repository, and the cloud configuration uploaded from `cloud.yml`.

    The global state is currently stored in S3 bucket named after the application. I.e., for an application called “example” the bucket is called `jecloud-example` and the file is called `state.yml`. (This is surely a problem, since S3 buckets namespace is shared among all users. Will be changed in the future.)

* *Cloud configuration file*, conventionally called `cloud.yml`, is where you define the deployment details of your application. (Currently it defines a EC2 instance type and EC2 ami for the server, but much more is coming.)

    The master copy of this configuration is stored inside the global cloud state on S3, but you are expected to keep a local copy (probably committed to your source repository). This local file is only read by JeCloud when you pass it to `jecloud apply` command, which uploads the configuration to S3.

* Any requests are recorded inside the state file, and then *roll-forward* (`jecloud fwd`) is used to update the physical servers. Thus the real state of the servers eventually becomes consistent with the demanded state. (Roll-forward means that the changes specified in the state file are eventually applied, and if the initial processing has failed or crashed, it will be retried later.)


JeCloud command line
--------------------

All of the following commands (except `jecloud init`) expect to find the cloud access information in `cloud-access.yml` file in the current directory or one of its parents. You can explicitly specify a path to this file using `--access-file` option.

Note that the only command that does actual changes to the cloud is `fwd`. Other commands like `apply` and `deploy` simply record the requested state in the cloud state file on S3 and then invoke `fwd` internally.

* `jecloud init APPNAME`

    Generate initial versions of `cloud.yml` and `cloud-access.yml` to get you started.

    Additionally, generates `cloud-access.yml.example` which should be committed to Git instead of `cloud-access.yml`, and adds `cloud-access.yml` to `.gitignore` (because you should never commit passwords and keys).

* `jecloud status` (or simply `jecloud` — status is the default command)

    Show the status of the cloud. Currently this displays the contents of the cloud state file, the list of Amazon EC2 instances and the list of servers managed by JeCloud.

* `jecloud upload-git-ssh-key my_deployment_key`

    Saves the given SSH private key into the cloud state file. This key will be used to access the Git repository on deployment. You should generate a separate key specifically for this purpose (`ssh-keygen -t rsa`) and add it to GitHub as a deployment key for your repository.

    (If you're using other private repositories as Git submodules, you will want to add the key to your GitHub account keys instead of your repository deployment keys.)

* `jecloud apply path/to/cloud.yml`

    Upload the given cloud configuration file and apply it to the cloud. This will, if needed:

    * create a EC2 key pair
    * start a new server instance on EC2
    * install JeCloud on the newly created instance

    If the processing fails (crashes, times out, etc), you can retry/continue by running `jecloud fwd`.

* `jecloud fwd`

    Runs roll-forward processing, i.e. tries to apply the changes that have been requested but have not been applied yet.

    This is the heart of the cloud management/monitoring solution. When a real hosted cloud monitor will be added to JeCloud stack, it will run `jecloud fwd` every minute from cron on the master monitoring node.

* `jecloud terminate`

    Terminates all the servers in your EC2 account (after asking for confirmation). Use this after you've done playing with JeCloud, or to start afresh. Needs to be fixed soon to only terminate the servers managed by JeCloud.


Known issues
------------

When connecting via SSH to a recently launched instance, the connection sometimes hangs, and no sensible timeout seems to exist. (And yes, I've tried passing `:timeout` to Net::SSH.) You need to manually press Ctrl-C to continue processing.


Roadmap for 0.1 (i.e. what I'm working on right now)
----------------------------------------------------

* deploy a single environment on a single server, running a ‘Hello, world’ node.js app
* full server setup workflow from the very start


Roadmap for 1.0
---------------

Version 1.0 is a version that will successfully host my (and, chances are, your) startup during its early stages. Thus the following requirements:

* multiple environments: production, stage, can quickly create and destroy environments (e.g. to test throughput on various deployment configurations)
* EC2 only, unless someone helps
* set up the servers for an environment from scratch (i.e. a fully automated path from a new AWS account to a running stack)
* Node.js, MongoDB, Redis
* background work queue (think CPU-intensive image processing jobs, you want to rate-limit them, have insights into queue contents, and probably offload that to a different machine)
* S3 backups
* outgoing email via something like Sendgrid (no time to fuss around with a proper MX setup)
* manual scaling (add/remove app servers, reconfigure sharding etc)
* explicit persistent state (of the cloud monitoring app) that can be inspected and altered manually in critical cases — a JSON file on S3 that all components of the cloud obey
* Git-based deploys — more likely pulling from GitHub (using deployment keys) than pushing directly to the cloud, with a deploy initiated by a web hook


Roadmap for 1.2
---------------

* log rotation (so that logs don't eat up all the disk space)
* predictable updates (if I tested with node 2.1, I don't want to get 2.2 automatically)


Contributing to JeCloud
-----------------------

* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it
* Fork the project
* Start a feature/bugfix branch
* Commit and push until you are happy with your contribution
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.


Copyright, License, Contributors
--------------------------------

Copyright (c) 2010 Andrey Tarantsov.

Distributed under the terms of the MIT license (see LICENSE.txt for further details).

A list of contributors, in the order of their first contribution:

* Andrey Tarantsov ([github.com/andreyvit](https://github.com/andreyvit) | [@andreyvit](http://twitter.com/andreyvit/) | andreyvit@gmail.com)


Thoughts about how JeCloud should work in the future
====================================================


Server side
-----------

Except for the code of JeCloud (which is a gem), all other JeCloud-related stuff on the server is stored under `/var/cloud`.

There is a global state file `/var/cloud/sys/server.json` and per-application state files `/var/cloud/APP/ENV/app.json`. The intent is to store only the bare minimum of the state that cannot be figured otherwise, and to accommodate external changes as much as possible (i.e. if you go and mess with the server, JeCloud should pick things up from where you left off).

We use roll-forward semantics for the recorded server state. E.g., to deploy a new version, we first record that we are deploying a version with the given ID, then run a general rollforward script that handles the actual process. If a server crashes during the operation, it will be completed the next time rollforward is run (on next boot or from cron).

Only one instance of rollforward can be running at any given time, so it's guarded with a pid file. (Could also be a daemon, but who wants an extra daemon on production systems.)


Roll-forward
------------

Repeat until there is nothing to do:

1. Install required prerequisites for each of the deployed applications (explicitly mentioned stuff like gems, yum packages, npm packages etc).
1. Install required prerequisites for the services (Node.js, MongoDB etc) enabled for (at least one of) the deployed applications.
1. Cleanup old application versions that are not referenced from app.json (and are older than, say, 1 week, so that deployments can be quickly rolled back in a week).
1. Deploy the new versions of applications.

A running roll-forward process PID is recorded in `/var/cloud/sys/pids/rollforward.pid`, and the log goes to `/var/cloud/sys/logs/rollforward.log`.


How it works: deployment
------------------------

Starting a deployment:

* `jecloud deploy /some/path` is invoked (this syntax is temporary for v0.1)
* if there is no server to deploy to, it is created and set up (just the bare minimum to run the server-side code of JeCloud)
* the working directory is compressed into source.tar.bz2, which gets hashed to get a ‘commit ID’ (say, 1fe35a)
* source.tar.bz2 is uploaded to the server into `/var/cloud/myapp/myenv/source/versions/1fe35a.tar.bz2`
* `jecloud update-server deploy 1fe35a` is run on the server, which aborts the previous deployment if any (adds it to `aborted_deployment_versions`), records the information about the new deployment version and spawns roll-forward.

Rolling forward:

* all service hooks are told we are preparing to deploy (this would be a good time to run some sanity check, e.g. is the DB schema up to date?)
* symlink `/var/cloud/myapp/myenv/source/versions/current` is updated to point to the new version directory
* all service hooks are told we have deployed a new version (at this point fugue restarts node)

If a deployment fails, the failed version info is added into `recent_failed_deployments` key of `app.yaml` (capped to last 100 entries).

When a deployment succeeds, `current_version` is updated and `deployment` is removed.


How it works: initial server setup
----------------------------------

When there is nothing to deploy, there is also no need for a running server. So a server is only set up as part of a deployment.

Once a server is created and SSH connection succeeds, we install the required software (rubygems, jecloud) and run `jecloud update-server init` to reconfigure the server (add jecloud to cron, etc).


Service hooks
-------------

The core of JeCloud knows nothing about the specific services like Node.js or MongoDB. Some common concepts are supported in the core (shards, replicas).

Service hooks should be very easy to write, so that everyone can throw a quick class together and get his favorite service running with JeCloud.


Server state file
-----------------

`/var/cloud/sys/server.json`:

    {
    }


Application state file
----------------------

`/var/cloud/APP/ENV/state.json`:

    {
      "current_version": "841bc9",
      "deployment": {
        "version": "1fe35a",
        "request_date": "2010-12-20 06:07:00",
        "start_date": "2010-12-20 06:08:00",
        "state": "extracting-sources"
      },
      "aborted_deployment_versions": ["2c3e92"],
      "recent_failed_deployments": [
        {
          "version": "7c3e92",
          "request_date": "2010-12-20 06:07:00",
          "start_date": "2010-12-20 06:08:00",
          "fail_date": "2010-12-20 06:09:00",
          "reason": "out of disk space"
        }
      ]
    }
