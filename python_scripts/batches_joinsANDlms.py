import pandas as pd
import glob
import numpy as np
import matplotlib.pyplot as plt
import statsmodels.api as sm
import pickle

def batches_joinsANDlms(group_age, region, metric='vol', batches_dir = '/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/batches/'):
    """Returns a pickle file with prediction intervals of ages within an age group.
     
    Joins all batches, selects all controls within the age group, builds linear models to return a pickle file containing prediction intervals of ages whithin the age group.
     
    Args:
        group_age (str): Group age of prediction intervals (older group: "40ormoreyears", younger group: "lessthan40years")
        region (str): Freesurfer's brain part to be exported (Left hemisphere: "lh", Right hemisphere: "rh", Subcortical regions: "seg", Brainstem structures: "brainstem", Hippocampal subfields: "hippo")
        metric (str): Freesurfer's metric to be exported ( default is "vol", Volume: "vol", Surface area: "area", Thickness: "thick")
        batches_dir (str): Directory where to save the output pickle file ( default is "/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/batches/")
     
    Returns:
        .pkl (pickle): Pickle file with prediction intervals of ages within the age group. Saved at batches_dir+'prediction_intervals' 
    """
    	
    # In[169]:
    
    

    
    #group_age = "40ormoreyears" #lessthan40years
    #region = 'lh' #seg, rh, brainstem, hippo
    #metric = 'vol' #area, thick
    #batches_dir = '/home/neurocogn/N1.0Dir/NezihNiegu/neuroimaging_processor/Volumetry/batches/'
    
    
    # In[162]:
    if metric == 'vol':
        metric_label = 'volume'
    if metric == 'area':
        metric_label = 'area'
    if metric == 'thick':
        metric_label = 'thickness'
    
    if region == 'lh':
        column_name = 'lh.aparc.'+metric_label
    if region == 'rh':
        column_name = 'rh.aparc.'+metric_label
    if region == 'seg':
        column_name = 'Measure:'+metric_label
    if region == 'brainstem' or region == 'hippo':
        column_name = 'Subject'
    
    
    # In[172]:
    

    all_IDs = pd.read_csv(batches_dir+"all_controls_demographics.csv")
    
    if group_age == "lessthan40years":
        ID_selection_age = all_IDs.loc[all_IDs['Age'] < 40]
        range_min = 15
        range_max = 40
    if group_age == "40ormoreyears":
        ID_selection_age = all_IDs.loc[all_IDs['Age'] >= 40]
        range_min = 40
        range_max = 101
    #ID_selection_gender = ID_selection_age.loc[ID_selection_age['Gender'] == 'M']
    #ID_selection_index = ID_selection_gender.loc[ID_selection_gender['index'] <= 400]
    ID_selection = ID_selection_age #_gender
    
    
    # In[164]:
    

    if region == 'lh' or region == 'rh' or region == 'seg':
        for ICBMfile in glob.iglob(batches_dir+'*'+region+'*'+metric+'*'):
            print(ICBMfile)
        
        ICBM = pd.read_csv(ICBMfile,sep="\t")
        ICBM[column_name] = ICBM[column_name].str.slice(10,13,1)
        print(ICBM[column_name])
        ICBM[column_name] = pd.to_numeric(ICBM[column_name])
        ICBM = ICBM.rename(columns={column_name: 'Num'})
        
        ID_selection['Num'] = ID_selection['Num'].astype(str)
        ICBM['Num'] = ICBM['Num'].astype(str)
        
        inner_join = pd.merge(ID_selection, ICBM, on ='Num', how ='inner')
        inner_join = inner_join.drop(columns=['index','Gender','DB'])
    
        batches=[]
        for batch in glob.iglob(batches_dir+'batch_*/folder_*/*'+region+'*'+metric+'*'):
    	    batches.append(batch)
        batches.sort()
        
        batch1fold1 = pd.read_csv(batches[0],sep="\t")
        batch1fold2 = pd.read_csv(batches[1],sep="\t")
        batch2fold1 = pd.read_csv(batches[2],sep="\t")
        batch2fold2 = pd.read_csv(batches[3],sep="\t")
        batch3fold1 = pd.read_csv(batches[4],sep="\t")
        batch3fold2 = pd.read_csv(batches[5],sep="\t")
        batch4fold1 = pd.read_csv(batches[6],sep="\t")
        batch4fold2 = pd.read_csv(batches[7],sep="\t")
    
        frames = [batch1fold1, batch1fold2, batch2fold1, batch2fold2, batch3fold1, batch3fold2.loc[23:29,:]]
        batches1_3 = pd.concat(frames)
        batches1_3[column_name] = batches1_3[column_name].str.slice(5,9,1)
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("003_", "003") 
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("011_", "011")
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("013_", "013")
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("016_", "016")
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("020_", "020")
        #batches1_3['lh.aparc.volume'] = batches1_3['lh.aparc.volume'].replace("022_", "022")
        #batches1_3['lh.aparc.volume'] = pd.to_numeric(batches1_3['lh.aparc.volume'])
        batches1_3 = batches1_3.rename(columns={column_name: 'Num'})
    
        frames2 = [batch3fold2.loc[0:22,:], batch4fold1, batch4fold2]
        batches4 = pd.concat(frames2)
        batches4[column_name] = batches4[column_name].str.slice(5,15,1)
        batches4 = batches4.rename(columns={column_name: 'Num'})
    
        frames3 = [batches1_3, batches4]
        batches1_4 = pd.concat(frames3)
    
        ID_selection['Num'] = ID_selection['Num'].astype(str)
        batches1_4['Num'] = batches1_4['Num'].astype(str)
    
        inner_join2 = pd.merge(ID_selection, batches1_4, on ='Num', how ='inner')
        inner_join2 = inner_join2.drop(columns=['index','Gender','DB'])
                
        frames2 = [inner_join, inner_join2]
        batches_fusion = pd.concat(frames2)
                
        batches_fusion = batches_fusion.rename(columns={'Num': column_name})
    
    
    # In[165]:
    
    
    if region == 'brainstem' or region == 'hippo':
        batches=[]
        for batch in glob.iglob(batches_dir+'*'+region+'*'):
            batches.append(batch)
        batches.sort()
        
        batch0 = pd.read_csv(batches[0],sep=" ")
        batch1 = pd.read_csv(batches[1],sep=" ")
        batch2 = pd.read_csv(batches[2],sep=" ")
        batch3 = pd.read_csv(batches[3],sep=" ")
        batch4 = pd.read_csv(batches[4],sep=" ")

        batch0[column_name] = batch0[column_name].str.slice(10,13,1)
        batch0 = batch0.rename(columns={column_name: 'Num'})       

        frames = [batch1, batch2, batch3.loc[23:,:]]
        batches1_3 = pd.concat(frames)
        batches1_3[column_name] = batches1_3[column_name].str.slice(5,9,1)
        batches1_3 = batches1_3.rename(columns={column_name: 'Num'})
        
        frames2 = [batch3.loc[0:22,:], batch4]
        batches4 = pd.concat(frames2)
        batches4 = batches4[:-3]
        batches4[column_name] = batches4[column_name].str.slice(5,15,1)
        batches4 = batches4.rename(columns={column_name: 'Num'})
    	
        frames3 = [batch0, batches1_3, batches4]
        batches1_4 = pd.concat(frames3)    
        
        ID_selection['Num'] = ID_selection['Num'].astype(str)
        batches1_4['Num'] = batches1_4['Num'].astype(str)
        
        inner_join2 = pd.merge(ID_selection, batches1_4, on ='Num', how ='inner')
        inner_join2 = inner_join2.drop(columns=['index','Gender','DB'])
        batches_fusion = inner_join2
        batches_fusion = batches_fusion.rename(columns={'Num': column_name})
    
    
    # In[178]:
    
    
    dictionary = {}
    for age_loop in range(range_min,range_max):
        P=[]
        label = []
        low_reference = []
        high_reference = []
        for i in batches_fusion.columns[2:]:
            x2 = np.array(batches_fusion['Age'])
            y2 = np.array(batches_fusion[i])
            #print(i)
            
            x2_constant = sm.add_constant(x2)
            ols = sm.OLS(y2, x2_constant)
            ols_result = ols.fit()
            #print(ols_result.params)
            ols_result.HC0_se
            
            confint = ols_result.conf_int(0.05)
            

            predictions_patient = ols_result.get_prediction((1,age_loop))
            predictions_patient_df = predictions_patient.summary_frame(alpha=0.05)
            #P_slope = (predictions_patient_df['obs_ci_upper'][0]-predictions_patient_df['obs_ci_lower'][0])/(97.5-2.5)
            #P_intercept = predictions_patient_df['obs_ci_lower'][0]-P_slope*2.5
            #P_tmp = (subcort_subject[i]-P_intercept)/P_slope 
            #P.append(P_tmp)
	    
            label.append(i)
            low_reference.append(predictions_patient_df['obs_ci_lower'][0])
            high_reference.append(predictions_patient_df['obs_ci_upper'][0])
            #plot_linear_model(ols_result, patient_age)
        dictionary[age_loop] = np.array([label, low_reference, high_reference])
    print(batches_fusion['Age'])
    print(batches_fusion['Age'].shape)
    #plt.show()
        
    
    
    # In[177]:
    
    
    f = open(batches_dir+"prediction_intervals/"+region+"_"+metric+"_"+group_age+".pkl","wb")
    pickle.dump(dictionary,f)
    f.close()

