Docker has matured a lot since it was released nearly 4 years ago. We've been watching it closely at Caktus, and have been thrilled by the adoption -- both by the community and by service providers. As a team of Python and Django developers, we're always searching for best of breed deployment tools. Docker is a clear fit for packaging the underlying code for many projects, including the Python and Django apps we build at Caktus.

Technical overview
------------------

There are many ways to containerize a Python/Django app, no one of which could be considered "the best." That being said, I think the following approach provides a good balance of simplicity, configurability, and container size. The specific tools I'll be using are: `Docker <https://www.docker.com/>`_ (of course), `Alpine Linux <https://alpinelinux.org/>`_, and `uWSGI <https://uwsgi-docs.readthedocs.io/>`_.

Alpine Linux is a simple, lightweight Linux distribution based on `musl libc <https://www.musl-libc.org/>`_ and `Busybox <https://busybox.net/about.html>`_. Its main claim to fame on the container landscape is that it can create a `very small (5MB) Docker image <https://hub.docker.com/_/alpine/>`_. Typically one's application will be much larger than that after the code and all dependencies have been included, but the container will still be much smaller than if based on a general-purpose Linux distribution.

There are many WSGI servers available for Python, and we use both Gunicorn and uWSGI at Caktus. A couple of the benefits of uWSGI are that (1) it's almost entirely configurable through environment variables (which fits well with containers), and (2) it includes `native HTTP support <http://uwsgi-docs.readthedocs.io/en/latest/HTTP.html#can-i-use-uwsgi-s-http-capabilities-in-production>`_, which can circumvent the need for a separate HTTP server like Apache or Nginx, provided static files are hosted on a 3rd-party CDN such as Amazon S3.

The Dockerfile
--------------

Without further ado, here's a production-ready ``Dockerfile`` you can use as a starting point for your project (it should be added in your top level project directory, next to the ``manage.py`` script provided by your Django project):

.. code-block:: docker

    FROM python:3.5-alpine

    # Copy in your requirements file
    ADD requirements.txt /requirements.txt

    # OR, if you're using a directory for your requirements, copy everything (comment out the above and uncomment this if so):
    # ADD requirements /requirements

    # Install build deps, then run `pip install`, then remove unneeded build deps all in a single step. Correct the path to your production requirements file, if needed.
    RUN set -ex \
    	&& apk add --no-cache --virtual .build-deps \
    		gcc \
    		make \
    		libc-dev \
    		musl-dev \
    		linux-headers \
    		pcre-dev \
    		postgresql-dev \
    	&& pyvenv /venv \
    	&& /venv/bin/pip install -U pip \
    	&& LIBRARY_PATH=/lib:/usr/lib /bin/sh -c "/venv/bin/pip install --no-cache-dir -r /requirements.txt" \
    	&& runDeps="$( \
    		scanelf --needed --nobanner --recursive /venv \
    			| awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
    			| sort -u \
    			| xargs -r apk info --installed \
    			| sort -u \
    	)" \
    	&& apk add --virtual .python-rundeps $runDeps \
    	&& apk del .build-deps

    # Copy your application code to the container (make sure you create a .dockerignore file if any large files or directories should be excluded)
    RUN mkdir /code/
    WORKDIR /code/
    ADD . /code/

    # uWSGI will listen on this port
    EXPOSE 8000

    # Add any custom, static environment variables needed by Django or your settings file here:
    ENV DJANGO_SETTINGS_MODULE=my_project.settings.deploy

    # uWSGI configuration (customize as needed):
    ENV UWSGI_VIRTUALENV=/venv UWSGI_WSGI_FILE=my_project/wsgi.py UWSGI_HTTP=:8000 UWSGI_MASTER=1 UWSGI_WORKERS=2 UWSGI_THREADS=8 UWSGI_UID=1000 UWSGI_GID=2000 UWSGI_LAZY_APPS=1 UWSGI_WSGI_ENV_BEHAVIOR=holy

    # Call collectstatic (customize the following line with the minimal environment variables needed for manage.py to run):
    RUN DATABASE_URL=none /venv/bin/python manage.py collectstatic --noinput

    # Start uWSGI
    CMD ["/venv/bin/uwsgi", "--http-auto-chunked", "--http-keepalive"]

We extend from the Alpine flavor of the official Docker image for Python 3.5, copy the folder containing our requirements files to the container, and then, in a single line, (a) install the OS dependencies needed, (b) ``pip install`` the requirements themselves (edit this line to match the location of your requirements file, if needed), (c) scan our virtual environment for any shared libraries linked to by the requirements we installed, and (d) remove the C compiler and any other OS packages no longer needed, except those identified in step (c) (this approach, using ``scanelf``, is borrowed from the underlying `3.5-alpine Dockerfile <https://github.com/docker-library/python/blob/9f67896dbaf1b86f2446b0ab981aa20f4d336132/3.5/alpine/Dockerfile>`_). It's important to keep this all on one line so that Docker will cache the entire operation as a single layer.

You'll notice I've only included a minimal set of OS dependencies here. If this is an established production app, you'll most likely need to visit https://pkgs.alpinelinux.org/packages, search for the Alpine Linux package names of the OS dependencies you need, including the ``-dev`` supplemental packages as needed, and add them to the list above.

Next, we copy our application code to the image, set some default environment variables, and run ``collectstatic``. Be sure to change the values for ``DJANGO_SETTINGS_MODULE`` and ``UWSGI_WSGI_FILE`` to the correct paths for your application (note that the former requires a Python package path, while the latter requires a file system path). In the event you're not serving static media directly from the container (e.g., with `Whitenoise <http://whitenoise.evans.io/en/stable/>`_), the ``collectstatic command`` can also be removed.

Finally, the ``--http-auto-chunked`` and ``--http-keepalive`` options to uWSGI are needed in the event the container will be hosted behind an Amazon Elastic Load Balancer (ELB), because Django doesn't set a valid ``Content-Length`` header by default, unless the ``ConditionalGetMiddleware`` is enabled. See `the note <http://uwsgi-docs.readthedocs.io/en/latest/HTTP.html#can-i-use-uwsgi-s-http-capabilities-in-production>`_ at the end of the uWSGI documentation on HTTP support for further detail.

Building and testing the container
----------------------------------

Now that you have the essentials in place, you can build your Docker image locally as follows:

.. code-block:: bash

    docker build -t my-app .

This will go through all the commands in your Dockerfile, and if successful, store an image with your local Docker server that you could then run:

.. code-block:: bash

    docker run -e DATABASE_URL=none -t my-app

This command is merely a smoke test to make sure uWSGI runs, and won't connect to a database or any other external services.

Running commands during container start-up
------------------------------------------

As an optional final step, I recommend creating an ``ENTRYPOINT`` script to run commands as needed during container start-up. This will let us accomplish any number of things, such as making sure Postgres is available or running ``migrate`` or ``collectstatic`` during container start-up. Save the following to a file named ``docker-entrypoint.sh`` in the same directory as your ``Dockerfile``:

.. code-block:: bash

    #!/bin/sh
    set -e

    until psql $DATABASE_URL -c '\l'; do
      >&2 echo "Postgres is unavailable - sleeping"
      sleep 1
    done

    >&2 echo "Postgres is up - continuing"

    if [ "x$DJANGO_MANAGEPY_MIGRATE" = 'xon' ]; then
        /venv/bin/python manage.py migrate --noinput
    fi

    if [ "x$DJANGO_MANAGEPY_COLLECTSTATIC" = 'xon' ]; then
        /venv/bin/python manage.py collectstatic --noinput
    fi

    exec "$@"


Next, add the following line to your ``Dockerfile``, just above the ``CMD`` statement:

.. code-block:: docker

    ENTRYPOINT ["/code/docker-entrypoint.sh"]

This will (a) make sure a database is available (usually only needed when used with Docker Compose), (b) run outstanding migrations, if any, if the ``DJANGO_MANAGEPY_MIGRATE`` is set to ``on`` in your environment, and (c) run ``collectstatic`` if ``DJANGO_MANAGEPY_COLLECTSTATIC`` is set to ``on`` in your environment. Even if you add this entrypoint script as-is, you could still choose to run ``migrate`` or ``collectstatic`` in separate steps in your deployment before releasing the new container. The only reason you might not want to do this is if your application is highly sensitive to container start-up time, or if you want to avoid any database calls as the container starts up (e.g., for local testing). If you do rely on these commands being run during container start-up, be sure to set the relevant variables in your container's environment.

Creating a production-like environment locally with Docker Compose
------------------------------------------------------------------

To run a complete copy of production services locally, you can use `Docker Compose <https://docs.docker.com/compose/>`_. The following ``docker-compose.yml`` will create a barebones, ephemeral, AWS-like container environment with Postgres and Redis for testing your production environment locally.

*This is intended for local testing of your production environment only, and will not save data from stateful services like Postgres upon container shutdown.*

.. code-block:: yaml

    version: '2'

    services:
      db:
        environment:
          POSTGRES_DB: app_db
          POSTGRES_USER: app_user
          POSTGRES_PASSWORD: changeme
        restart: always
        image: postgres:9.6
        expose:
          - "5432"
      redis:
        restart: always
        image: redis:3.0
        expose:
          - "6379"
      app:
        environment:
          DATABASE_URL: postgres://app_user:changeme@db/app_db
          REDIS_URL: redis://redis
          DJANGO_MANAGEPY_MIGRATE: "on"
        build:
          context: .
          dockerfile: ./Dockerfile
        links:
          - db:db
          - redis:redis
        ports:
          - "8000:8000"

Copy this into a file named ``docker-compose.yml`` in the same directory as your ``Dockerfile``, and then run:

.. code-block:: bash

    docker-compose up --build -d

This downloads (or builds) and starts the three containers listed above. You can view output from the containers by running:

.. code-block:: bash

    docker-compose logs

If all services launched successfully, you should now be able to access your application at http://localhost:8000/ in a web browser.

Extra: Blocking ``Invalid HTTP_HOST header`` errors with uWSGI
--------------------------------------------------------------

To avoid Django's ``Invalid HTTP_HOST header`` errors (and prevent any such spurious requests from taking up any more CPU cycles than absolutely necessary), you can also configure uWSGI to return an ``HTTP 400`` response immediately without ever invoking your application code. This can be accomplished by adding a command line option to uWSGI in your ``Dockerfile`` script, e.g., ``--route-host='^(?!www.myapp.com$) break:400'`` (note, the single quotes are required here, to prevent the shell from attempting to interpret the regular expression). If preferred (for example, in the event you use a different domain for staging and production), you can accomplish the same end by setting an environment variable via your hosting platform: ``UWSGI_ROUTE_HOST=‘^(?!www.myapp.com$) break:400'``.

That concludes this high-level introduction to containerizing your Python/Django app for hosting on AWS Elastic Beanstalk (EB), Elastic Container Service (ECS), or elsewhere. Each application and Dockerfile will be slightly different, but I hope this provides a good starting point for your containers. Shameless plug: If you're looking for a simple (and at least temporarily free) way to test your Docker containers on AWS using an Elastic Beanstalk Multicontainer Docker environment or the Elastic Container Service, checkout `AWS Container Basics <https://github.com/tobiasmcnulty/aws-container-basics>`_ (more on this soon). Good luck!

**Update 1 (March 31, 2017):** There is no need for ``depends_on`` in container definitions that already include ``links``. This has been removed. Thanks Anderson Lima for the tip!

**Update 2 (March 31, 2017):** Adding ``--no-cache-dir`` to the ``pip install`` command saves a additional disk space, as this prevents ``pip`` from `caching downloads <https://pip.pypa.io/en/stable/reference/pip_install/#caching>`_ and `caching wheels <https://pip.pypa.io/en/stable/reference/pip_install/#wheel-cache>`_ locally. Since you won't need to install requirements again after the Docker image has been created, this can be added to the ``pip install`` command. The post has been updated. Thanks Hemanth Kumar for the tip!

**Update 3 (May 30, 2017):** uWSGI contains a lot of optimizations for running many apps from the same uWSGI process. These optimizations aren't really needed when running a single app in a Docker container, and can `cause issues <https://discuss.newrelic.com/t/newrelic-agent-produces-system-error/43446/2>`_ when used with certain 3rd-party packages. I've added ``UWSGI_LAZY_APPS=1`` and ``UWSGI_WSGI_ENV_BEHAVIOR=holy`` to the uWSGI configuration to provide a more stable uWSGI experience (the latter will be the default in the next uWSGI release).