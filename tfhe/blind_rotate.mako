<%def name="BlindRotateKS(
    kernel_declaration, lwe_a, lwe_b, accum_a, gsw, ks_a, ks_b, bara, cdata_forward, cdata_inverse, n)">
<%
    tpt = transform.threads_per_transform
    p_ept = transform.polynomial_length // transform.threads_per_transform
    tr_ept = transform.transform_length // transform.threads_per_transform

    # Makes the code a bit simpler, can be lifted if necessary
    assert transform.polynomial_length % tpt == 0
    assert transform.transform_length % tpt == 0
    assert transform.cdata_fw.size % tpt == 0
    assert transform.cdata_inv.size % tpt == 0

    temp_ctype = dtypes.ctype(transform.temp_dtype)

    tr_size = transform.transform_length * transform.elem_dtype.itemsize
    temp_size = transform.temp_length * transform.temp_dtype.itemsize
    sh_size = max(tr_size, temp_size)
    sh_length_tr = sh_size // transform.elem_dtype.itemsize
%>


${kernel_declaration}
{
    VIRTUAL_SKIP_THREADS;

    // Buffers 0-3 are used as temporary arrays and output arrays for forward transformations.
    // Buffers 0 and 4 are used as output arrays for multiplication in transformed space.
    LOCAL_MEM char sh_char[${sh_size * 5}];
    LOCAL_MEM ${accum_a.ctype} shared_accum[${2 * transform.polynomial_length}];

    LOCAL_MEM_ARG ${tr_ctype}* sh = (LOCAL_MEM_ARG ${tr_ctype}*)sh_char;

    const unsigned int batch_id = virtual_group_id(0);
    const unsigned int tid = virtual_local_id(1);
    const unsigned int transform_id = tid / ${transform.threads_per_transform};
    const unsigned int k_id = transform_id / ${l};
    const unsigned int l_id = transform_id % ${l};
    const unsigned int thread_in_transform = tid % ${transform.threads_per_transform};
    const unsigned int bdim = virtual_local_size(1);

    // Load accum
    if (tid < ${2 * transform.threads_per_transform})
    {
        #pragma unroll
        for (unsigned int i = 0; i < ${p_ept}; i++)
        {
            shared_accum[l_id * ${transform.polynomial_length} + i * ${tpt} + thread_in_transform] =
                ${accum_a.load_combined_idx(slices)}(batch_id, l_id, i * ${tpt} + thread_in_transform);
        }
    }

    LOCAL_BARRIER;

    for (unsigned int bk_idx = 0; bk_idx < ${n}; bk_idx++)
    {

    ${bara.ctype} ai = ${bara.load_idx}(batch_id, bk_idx);

    if (tid < ${4 * transform.threads_per_transform})
    {
        const unsigned int decomp_bits = ${params.Bgbit};
        const unsigned int decomp_mask = (1 << decomp_bits) - 1;
        const int decomp_half = 1 << (decomp_bits - 1);
        const unsigned int decomp_offset = (0x1u << 31) + (0x1u << (31 - decomp_bits));

        <%
            conversion_multiplier = transform.polynomial_length // transform.transform_length;
        %>

        %for q in range(conversion_multiplier):
        int temp${q};
        %endfor

        #pragma unroll
        for (int i = tid; i < ${transform.polynomial_length // conversion_multiplier}; i += bdim)
        {
            %for q in range(conversion_multiplier):
            int i${q} = i + ${transform.transform_length * q};
            unsigned int cmp${q} = (unsigned int)(i${q} < (ai & 1023));
            unsigned int neg${q} = -(cmp${q} ^ (ai >> 10));
            unsigned int pos${q} = -((1 - cmp${q}) ^ (ai >> 10));
            %endfor

            %for k_id in range(k + 1):

                %for q in range(conversion_multiplier):
                temp${q} = shared_accum[(${k_id << 10}) | ((i${q} - ai) & 1023)];
                temp${q} = (temp${q} & pos${q}) + ((-temp${q}) & neg${q});
                temp${q} -= shared_accum[(${k_id << 10}) | i${q}];
                // decomp temp
                temp${q} += decomp_offset;
                %endfor

                %for l_id in range(l):
                    sh[${(2*k_id + l_id) * sh_length_tr} + i] = ${transform.module}i32_to_elem(
                        %for q in range(conversion_multiplier):
                        ((temp${q} >> (32 - ${l_id + 1} * decomp_bits)) & decomp_mask) - decomp_half
                        %if q < conversion_multiplier - 1:
                        ,
                        %endif
                        %endfor
                        );
                %endfor
            %endfor
        }
    }

    LOCAL_BARRIER;

    if (tid < ${4 * transform.threads_per_transform})
    {
    ##%for k_in_id in range(k + 1):
        // Forward transform
        ${transform.module}forward_i32_shared(
            sh + (k_id * 2 + l_id) * ${sh_length_tr},
            (LOCAL_MEM_ARG ${transform.temp_ctype}*)(sh + (k_id * 2 + l_id) * ${sh_length_tr}),
            (${transform.module}CDATA_QUALIFIER ${transform.cdata_fw_ctype}*)${cdata_forward},
            thread_in_transform);
    ##%endfor
    }
    else
    {
        ${transform.module}noop2();
        ${transform.module}noop2();
    }

    LOCAL_BARRIER;

    ## Iterating in reverse order, because the output shared array overlaps the input one.
    %for k_out_id in (1, 0):
    if (tid < ${4 * transform.threads_per_transform})
    {
    ${tr_ctype} t, a, b;
        #pragma unroll
        for (unsigned int i = 0; i < ${transform.transform_length}; i += bdim)
        {
            t = ${tr_ctype}zero;
            %for k_in_id in range(k + 1):
            %for l_id in range(l):
            a = sh[${(k_in_id * 2 + l_id) * sh_length_tr} + i + tid];
            b = ${tr_ctype}pack(
                ${gsw.load_idx}(
                    bk_idx, ${k_in_id}, ${l_id}, ${k_out_id}, i + tid)
                );
            t = ${add}(t, ${mul}(a, b));
            %endfor
            %endfor
            sh[${k_out_id * 4 * sh_length_tr} + i + tid] = t;
        }
    }
    LOCAL_BARRIER;
    %endfor

    if (tid < ${2 * transform.threads_per_transform})
    {
    // Inverse transform
        ${transform.module}inverse_i32_shared_add(
            shared_accum + l_id * ${transform.polynomial_length},
            sh + l_id * ${4 * sh_length_tr},
            (LOCAL_MEM_ARG ${transform.temp_ctype}*)(sh + l_id * ${4 * sh_length_tr}),
            (${transform.module}CDATA_QUALIFIER ${transform.cdata_inv_ctype}*)${cdata_inverse},
            thread_in_transform);
    }
    else
    {
        ${transform.module}noop2();
    }

    LOCAL_BARRIER;
    }

    {
        ## inner_n
        const unsigned int lwe_n = 500;

        ## outer_n
        const unsigned int tlwe_n = 1024;
        const unsigned int decomp_bits = 2;
        const unsigned int decomp_size = 8;

        const int decomp_mask = (1u << decomp_bits) - 1;
        const int decomp_offset = 1u << (31 - decomp_size * decomp_bits);

        int tmp;
        int res;
        int val;

        for (int i = tid; i <= lwe_n; i += bdim)
        {
            res = (i == lwe_n) ? shared_accum[1024] : 0;
            for (int j = 0; j < tlwe_n; j ++)
            {
                if (j == 0)
                    tmp = shared_accum[0];
                else
                    tmp = -shared_accum[1024 - j];

                ##tmp = ${ai.load_combined_idx(slices)}(batch_id, j);
                tmp += decomp_offset;

                for (int k = 0; k < decomp_size; k++)
                {
                    val = (tmp >> (32 - (k + 1) * decomp_bits)) & decomp_mask;
                    if (val != 0)
                    {
                        if (i == lwe_n)
                        {
                            res -= ${ks_b.load_idx}(j, k, val);
                        }
                        else
                        {
                            res -= ${ks_a.load_idx}(j, k, val, i);
                        }
                    }
                }
            }
            if (i == lwe_n)
            {
                ${lwe_b.store_combined_idx(slices3)}(batch_id, res);
            }
            else
            {
                ${lwe_a.store_combined_idx(slices2)}(batch_id, i, res);
            }
        }
    }
}
</%def>
