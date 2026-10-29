..
   SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
   SPDX-License-Identifier: CC0-1.0

Greengrass Hello
================

``esp32s31-ggl-hello`` is a native AWS IoT Greengrass component
(``com.espressif.esp32s31.Hello``) for an ESP SoC running Greengrass
nucleus lite. Once started by Greengrass, it:

#. reads its ``message`` configuration over Greengrass IPC;
#. publishes the message to the local topic ``esp32s31/hello`` and receives
   it back (``ggpubsubd``);
#. subscribes to ``esp32s31/<thing>/hello`` on AWS IoT Core, publishes to it
   and receives the message back (``iotcored``), then prints
   ``hello: PASS``;
#. publishes ``{thing, uptime_s, mem_available_kb}`` to
   ``esp32s31/<thing>/heartbeat`` every ``heartbeatSeconds`` (default 30).

It exits with a non-zero status if any of the first three steps fails, so
Greengrass reports the component as ERRORED or BROKEN.

Prerequisites
-------------

* An ESP SoC board running Linux with Greengrass nucleus lite, provisioned
  as an AWS IoT Greengrass core device. The root of this repository builds
  such an image for the ESP32-S31 Function-CoreBoard.
* A RISC-V Linux cross-compiler whose sysroot holds the Greengrass SDK
  (``gg/*.h`` and ``libgg-sdk.a``, installed by the ``aws-greengrass-lite``
  package). The toolchain wrapper of the Buildroot output,
  ``<output>/host/bin/riscv64-esp-linux-musl-``, is such a compiler.
* For a cloud deployment: the AWS CLI with credentials for the account the
  core device belongs to.

Example Folder Contents
-----------------------

.. code-block:: text

   ├── kconfig.fragment        Kernel configuration requirements (none)
   ├── Makefile                Build and install rules
   ├── README.rst              This file
   ├── recipe.yaml             Greengrass component recipe
   └── src
       └── hello.c             Component source

Build
-----

The image built from the root of this repository already contains the
component (Buildroot package ``esp32s31-ggl-hello`` runs this Makefile). To
build it on its own:

.. code-block:: bash

   cd examples/cloud/greengrass-hello
   make CROSS_COMPILE=<output>/host/bin/riscv64-esp-linux-musl-

The executable is written to ``build/esp32s31-ggl-hello``. When a build
system sets ``CC``, the Makefile uses it and honours ``CPPFLAGS``,
``CFLAGS`` and ``LDFLAGS``. ``libgg-sdk.a`` is an LTO archive built with
hidden visibility, so the Makefile always compiles and links with
``-flto``.

To stage the executable and the recipe into a root filesystem:

.. code-block:: bash

   make CROSS_COMPILE=<output>/host/bin/riscv64-esp-linux-musl- \
       DESTDIR=/path/to/rootfs install

This installs ``/usr/bin/esp32s31-ggl-hello`` and
``/usr/share/esp32s31-ggl-hello/com.espressif.esp32s31.Hello-1.0.0.yaml``.

Deploy
------

The recipe has no artifacts: the executable must be on the device, as in
the image of this repository.

Local deployment, on the board:

.. code-block:: console

   # ggl-cli deploy -r /usr/share/esp32s31-ggl-hello \
         -c com.espressif.esp32s31.Hello=1.0.0

Recipes given to ``ggl-cli deploy -r`` are copied with their file mode, and
components run as ``gg_component``: keep the recipe world-readable.

Cloud deployment, from the host (registers the component and deploys it to
the thing group ``<thing>-group``):

.. code-block:: bash

   scripts/aws-deploy-hello.sh <thing-name>

Nucleus lite resolves cloud components for the platform
``{os: linux, architecture: riscv32, runtime: aws_nucleus_lite}``. The
recipe's manifest therefore states ``architecture: riscv32`` and
``runtime: "*"``. Without ``runtime``, the cloud rejects the deployment
with "doesn't claim platform ... compatibility".

Example Output
--------------

The component's output is in syslog, tagged with its name:

.. code-block:: console

   # grep com.espressif.esp32s31.Hello /var/log/messages
   ... com.espressif.esp32s31.Hello: hello: config message=Hello from ESP32-S31
   ... com.espressif.esp32s31.Hello: hello: local esp32s31/hello <- Hello from ESP32-S31
   ... com.espressif.esp32s31.Hello: hello: cloud esp32s31/esp32s31-fcb-eth/hello <- Hello from ESP32-S31
   ... com.espressif.esp32s31.Hello: hello: PASS
   ... com.espressif.esp32s31.Hello: hello: heartbeat {"thing":"esp32s31-fcb-eth","uptime_s":49,"mem_available_kb":5608} (0)

The heartbeat can be watched in the AWS IoT MQTT test client by
subscribing to ``esp32s31/+/heartbeat``.

Kernel Configuration Fragment
-----------------------------

The component needs no kernel option beyond networking, so
``kconfig.fragment`` contains no ``CONFIG_`` entries. Greengrass nucleus
lite, as built by this repository, needs ``CONFIG_CGROUPS``
(``board/esp32s31-fcb/linux-ggl-svc.fragment``).

Troubleshooting
---------------

Userspace (the component)
~~~~~~~~~~~~~~~~~~~~~~~~~

* **Its output:** ``grep com.espressif.esp32s31.Hello /var/log/messages``.
  Each step prints one line; the first failing step prints
  ``hello: ... failed: <error>`` and the component exits.
* ``hello: AWS_IOT_THING_NAME is not set``: the program was started by
  hand. Greengrass sets the variable when it runs the component.
* ``hello: IPC connect failed``: the component is not running under
  Greengrass (IPC refuses callers outside a component's unit), or
  ``ggipcd`` is down. Check the unit, below.
* ``hello: IoT Core round trip failed``: ``iotcored`` is not connected yet.
  Components can start before the MQTT connection is up. Check for
  ``Connected to IoT core`` in ``grep core.iotcored /var/log/messages``. A
  ``MQTTStatusNotConnected`` there means the device has no route to AWS IoT
  Core, or its clock is wrong (TLS fails before ``ntpd`` has set it).
* The recipe is ignored, or the deployment fails with no lifecycle step:
  lifecycle keys are case sensitive in nucleus lite (``run:``/``Script:``),
  and the recipe file must be named ``<component>-<version>.yaml``.

Framework (Greengrass and its service manager)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

* **Unit state:** ``systemctl show ggl.com.espressif.esp32s31.Hello.service``
  prints ``<unit> <ActiveState> <Result> <NRestarts> ...``. Healthy:
  ``active success 0``. ``failed start-limit-hit 3`` means the component
  kept exiting; Greengrass then reports it BROKEN.
* **All units:** ``/etc/init.d/S95greengrass status``. Every core unit
  should be ``active success 0``.
* **The component's processes:**
  ``cat /sys/fs/cgroup/ggl-svc/ggl.com.espressif.esp32s31.Hello.service/cgroup.procs``,
  and for one process ``cat /proc/<pid>/cgroup``, which must read
  ``0::/ggl-svc/ggl.com.espressif.esp32s31.Hello.service``. This is how
  IPC identifies the caller as the component.
* **Deployments:** ``grep core.ggdeploymentd /var/log/messages``. Each
  deployment ends with ``reporting job as SUCCEEDED`` or ``FAILED``,
  preceded by the reason.
* **Cloud view:** ``aws greengrassv2 list-installed-components
  --core-device-thing-name <thing>`` lists the component's lifecycle state
  as reported by the device.

Hardware driver (network)
~~~~~~~~~~~~~~~~~~~~~~~~~

The component reaches AWS IoT Core over ``eth0`` (``dwmac-esp32s31`` MAC,
YT8531 PHY).

* **Link:** ``cat /sys/class/net/eth0/carrier /sys/class/net/eth0/speed
  /sys/class/net/eth0/duplex`` should print ``1``, ``100`` and ``full``.
  ``dmesg | grep eth0`` shows ``Link is Up - 100Mbps/Full``, or the link
  going down.
* **Traffic and errors:** ``cat /proc/net/dev``. Receive or transmit
  errors and drops on ``eth0`` that keep rising point at the cable, the
  switch port or the PHY. Counters that do not move at all while the
  component publishes point at routing or the DMA path; check
  ``dmesg | grep stmmac`` for DMA errors.
