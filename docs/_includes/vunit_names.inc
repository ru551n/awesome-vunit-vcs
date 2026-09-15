.. note::

   Some names in the examples come from VUnit, not from this package:

   * `Run library <https://vunit.github.io/run/user_guide.html>`_: ``runner_cfg``,
     ``test_runner_setup``, ``test_runner_cleanup``, ``test_runner_watchdog``, ``test_suite``, ``run``,
     ``get_seed``, ``get_string_seed``, ``output_path`` and ``tb_path``.
   * `Check library <https://vunit.github.io/check/user_guide.html>`_: ``check``, ``check_true`` and
     ``check_equal``.
   * `Logging library <https://vunit.github.io/logging/user_guide.html>`_: ``get_id``, ``get_logger``,
     ``info``, ``disable_stop``, ``get_log_count`` and ``reset_log_count``.
   * `Communication library <https://vunit.github.io/com/user_guide.html>`_: ``net``, ``msg_t``,
     ``subscribe``, ``unsubscribe`` and ``receive``, and the
     `synchronization interface <https://vunit.github.io/verification_components/vci.html>`_ ``as_sync``
     and ``wait_until_idle``.
   * `Data types <https://vunit.github.io/data_types/user_guide.html>`_: ``integer_array_t`` with
     ``length``, ``get`` and ``deallocate``.
   * `OSVVM <https://github.com/OSVVM/OSVVM>`_: ``RandomPType``, which needs its own
     ``use osvvm.RandomPkg.RandomPType;``.

   The family context clause (``ethernet_context``, ``flash_context`` or ``property_context``) makes the
   VUnit names visible.
