Releasing
=========

Releases are published to PyPI by ``.github/workflows/release.yml`` with
`trusted publishing <https://docs.pypi.org/trusted-publishers/>`__, so no API token is stored in the
repository.

Making a release
----------------

The version lives in ``pyproject.toml`` and ``src/awesome_vunit_vcs/__init__.py``. A release is made
by tagging the commit that sets it:

.. code-block:: bash

    # 1. Set the same version in pyproject.toml and src/awesome_vunit_vcs/__init__.py
    python tools/release.py validate --tag v0.1.0a1   # the same check the workflow makes
    git commit -am "Release 0.1.0a1"
    git push
    # 2. Tag with the release notes as the tag message, then push the tag
    git tag -a v0.1.0a1 -m "Release notes..."
    git push origin v0.1.0a1

The tag starts the workflow, which:

#. checks the version against the tag,
#. builds the wheel and the sdist and checks their content,
#. installs the built wheel into a clean environment and runs ``examples/external_project`` against
   it with NVC,
#. publishes to PyPI,
#. creates the GitHub release with the tag message as its body. Pre-release versions become GitHub
   pre-releases.

Only pre-releases for now
-------------------------

``ALLOW_FINAL_RELEASES`` in ``tools/release.py`` is ``False``, so only ``aN``, ``bN``, ``rcN`` and
``.devN`` versions can be released. The package needs ``vunit_hdl>=5.0.0.dev12`` with package setup
hooks and ``vunit-python-bridge``, and neither is on PyPI, so a final release could not be installed.
Flip the switch once both are published.

Dev versions are hidden from ``pip install awesome-vunit-vcs`` unless ``--pre`` or an exact version
is given. PyPI never accepts the same version twice, even after a release is deleted, so every
release needs a new version number.

Rehearsal
---------

Running the workflow manually from the Actions tab does everything except publishing to PyPI and
creating the release. It gives the checkout a unique development version,
``<version>.dev<run number>`` (replacing an existing ``.devN``), and uploads that to
`TestPyPI <https://test.pypi.org/project/awesome-vunit-vcs/>`__.

Environments
------------

The ``pypi`` and ``testpypi`` GitHub environments hold the deployments; ``pypi`` accepts ``v*`` tags
only. PyPI and TestPyPI each trust this repository, the workflow ``release.yml`` and the environment
of the same name.
