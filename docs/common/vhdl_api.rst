VHDL API
========

.. important::

   This part is for authors of verification components, not for testbenches. Testbenches use the
   family contexts, such as ``ethernet_context``.

``vc_python_pkg`` is the only package that uses the VUnit Python bridge. Verification components
of every family go through it, so a change of the bridge API is absorbed in one place.

.. include:: /_generated/vhdl/common.vc.inc
