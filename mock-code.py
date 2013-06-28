
def job_state_change_cb(src_obj, fire_on, value):
    print "Callback: job state changed to '%s'\n" % value
    return True

def application():
    ec2_ctx = saga.Context('EC2')
    ec2_ctx.user_id = os.environ['EC2_ID']
    ec2_ctx.user_key = os.environ['EC2_KEY']

    ssh_ctx = saga.Context('SSH')
    ssh_ctx.user_id = 'root'
    ssh_ctx.user_key = os.environ['EC2_SSH_KEYPAIR']

    session = saga.Session(False) 
    session.contexts.append(ec2_ctx)
    session.contexts.append(ssh_ctx)

    try:
        # Launch a VM on Amazon EC 2
        rm = saga.resource.Manager("ec2://aws.amazon.com/", session=session)

        cd = saga.resource.ComputeDescription()
        cd.image = 'ami-0256b16b'
        cd.template = 'Small Instance'

        cr = rm.acquire(cd)
        cr.wait(saga.resource.ACTIVE)

        # Run a task on the VM (via SSH)
        js = saga.job.Service(cr.access, session=session)

        jd = saga.job.Description()
        jd.executable = '/opt/apps/bowtie/bin/bowtie'
        jd.arguments = ['-a', '-m 3', '-v 2 e_coli', '-c ATGCATCATGCGCCAT']
        jd.working_directory = '/home/oweidner/bowtie/run01/'

        job = js.create_job(jd)
        # register a callback with the job
        job.add_callback(saga.STATE, job_state_change_cb)

        # Run the job and wait for it to complete
        job.run()
        job.wait()

    except saga.SagaException, ex:
        # Catch all saga exceptions
        print "An exception occured: (%s) %s " % (ex.type, (str(ex)))
        # Trace back the exception. That can be helpful for debugging.
        print " \n*** Backtrace:\n %s" % ex.traceback

    finally:
        # shut down the VM
         cr.destroy()


